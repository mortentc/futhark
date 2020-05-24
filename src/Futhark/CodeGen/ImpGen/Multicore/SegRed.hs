module Futhark.CodeGen.ImpGen.Multicore.SegRed
  ( compileSegRed
  , compileSegRed'
  )
  where

import Control.Monad
import Data.List
import Prelude hiding (quot, rem)

import qualified Futhark.CodeGen.ImpCode.Multicore as Imp
import Futhark.CodeGen.ImpGen
import Futhark.IR.MCMem
import Futhark.Util (chunks)
import Futhark.CodeGen.ImpGen.Multicore.Base

type DoSegBody = (([(SubExp, [Imp.Exp])] -> MulticoreGen ()) -> MulticoreGen ())

-- Generate code for a SegRed construct
compileSegRed :: Pattern MCMem
                 -> SegSpace
                 -> [SegBinOp MCMem]
                 -> KernelBody MCMem
                 -> MulticoreGen ()
compileSegRed pat space reds kbody =
  compileSegRed' pat space reds $ \red_cont ->
    compileStms mempty (kernelBodyStms kbody) $ do
    let (red_res, map_res) = splitAt (segBinOpResults reds) $ kernelBodyResult kbody

    sComment "save map-out results" $ do
      let map_arrs = drop (segBinOpResults reds) $ patternElements pat
      zipWithM_ (compileThreadResult space) map_arrs map_res

    red_cont $ zip (map kernelResultSubExp red_res) $ repeat []

-- | Like 'compileSegRed', but where the body is a monadic action.
compileSegRed' :: Pattern MCMem
               -> SegSpace
               -> [SegBinOp MCMem]
               -> DoSegBody
               -> MulticoreGen ()
compileSegRed' pat space reds kbody
  | [_] <- unSegSpace space =
      nonsegmentedReduction pat space reds kbody
  | otherwise =
      segmentedReduction pat space reds kbody


-- | A SegBinOp with auxiliary information.
data SegBinOpSlug =
  SegBinOpSlug
  { slugOp :: SegBinOp MCMem
  , slugAccs :: [(VName, [Imp.Exp])]
    -- ^ Places to store accumulator in stage 1 reduction.
  }


slugBody :: SegBinOpSlug -> Body MCMem
slugBody = lambdaBody . segBinOpLambda . slugOp

slugParams :: SegBinOpSlug -> [LParam MCMem]
slugParams = lambdaParams . segBinOpLambda . slugOp

slugNeutral :: SegBinOpSlug -> [SubExp]
slugNeutral = segBinOpNeutral . slugOp

slugShape :: SegBinOpSlug -> Shape
slugShape = segBinOpShape . slugOp

accParams, nextParams :: SegBinOpSlug -> [LParam MCMem]
accParams slug = take (length (slugNeutral slug)) $ slugParams slug
nextParams slug = drop (length (slugNeutral slug)) $ slugParams slug

slugsComm :: [SegBinOpSlug] -> Commutativity
slugsComm = mconcat . map (segBinOpComm . slugOp)

segBinOpOpSlug :: Imp.Exp
               -> (SegBinOp MCMem, [VName])
               -> MulticoreGen SegBinOpSlug
segBinOpOpSlug local_tid (op, param_arrs) =
  SegBinOpSlug op <$> mapM (\param_arr -> return (param_arr, [local_tid])) param_arrs



nonsegmentedReduction :: Pattern MCMem
                      -> SegSpace
                      -> [SegBinOp MCMem]
                      -> DoSegBody
                      -> MulticoreGen ()
nonsegmentedReduction pat space reds kbody = do

  emit $ Imp.DebugPrint "nonsegmented segBinOp " Nothing
  let (is, ns) = unzip $ unSegSpace space
  ns' <- mapM toExp ns
  sUnpauseProfiling
  num_threads <- getNumThreads
  num_threads' <- toExp $ Var num_threads

  stage_one_red_arrs <- groupResultArrays (Var num_threads) reds

  flat_idx <- dPrim "iter" int32

  -- Thread id for indexing into each threads accumulator element(s)
  tid <- dPrim "tid" $ IntType Int32
  tid' <- toExp $ Var tid

  slugs <- mapM (segBinOpOpSlug tid') $ zip reds stage_one_red_arrs

  sFor "i" num_threads' $ \i -> do
    tid <-- i
    sComment "neutral-initialise the acc used by tid" $
      forM_ slugs $ \slug ->
        forM_ (zip (slugAccs slug) (slugNeutral slug)) $ \((acc, acc_is), ne) ->
          sLoopNest (slugShape slug) $ \vec_is ->
            copyDWIMFix acc (acc_is++vec_is) ne []

  fbody <- collect $ do
    dPrimV_ (segFlat space) tid'
    zipWithM_ dPrimV_ is $ unflattenIndex ns' $ Imp.vi32 flat_idx
    dScope Nothing $ scopeOfLParams $ concatMap slugParams slugs
    kbody $ \all_red_res -> do
      let all_red_res' = segBinOpChunks reds all_red_res
      forM_ (zip all_red_res' slugs) $ \(red_res, slug) ->
        sLoopNest (slugShape slug) $ \vec_is -> do
          sComment "load acc params" $
            forM_ (zip (accParams slug) (slugAccs slug)) $ \(p, (acc, acc_is)) ->
              copyDWIMFix (paramName p) [] (Var acc) (acc_is++vec_is)
          sComment "load next params" $
            forM_ (zip (nextParams slug) red_res) $ \(p, (res, res_is)) ->
              copyDWIMFix (paramName p) [] res (res_is ++ vec_is)
          sComment "red body" $
            compileStms mempty (bodyStms $ slugBody slug) $
                forM_ (zip (slugAccs slug) (bodyResult $ slugBody slug)) $
                  \((acc, acc_is), se) -> copyDWIMFix acc (acc_is++vec_is) se []

  dPrimV_ (segFlat space) 0
  seq_body <- sequentialRed stage_one_red_arrs flat_idx space reds kbody

  let freeVariables = namesToList $ freeIn (seq_body <> fbody) `namesSubtract`
                                    namesFromList (tid : [flat_idx])
  ts <- mapM lookupType freeVariables
  let freeParams = zipWith toParam freeVariables ts
      scheduling = case slugsComm slugs of
                     Commutative -> decideScheduling fbody
                     Noncommutative -> Imp.Static

  ntasks <- dPrim "num_tasks" $ IntType Int32
  ntasks' <- toExp $ Var ntasks
  emit $ Imp.Op $ Imp.ParLoop scheduling ntasks flat_idx (product ns') freeParams
                              (Imp.MulticoreFunc mempty fbody tid)
                              (Imp.SequentialFunc mempty seq_body)

  reds' <- renameSegBinOp reds
  slugs' <- mapM (segBinOpOpSlug tid') $ zip reds' stage_one_red_arrs


  dScope Nothing $ scopeOfLParams $ concatMap slugParams slugs'
  sComment "neutral-initialise the output" $
    forM_ slugs' $ \slug ->
      forM_ (zip (patternElements pat) (slugAccs slug)) $ \(pe, (acc, _)) ->
        sLoopNest (slugShape slug) $ \vec_is ->
          copyDWIMFix (patElemName pe) vec_is (Var acc) (0 : vec_is)

  sWhen (ntasks' .>. 0) $
    sFor "i" (ntasks'-1) $ \i' -> do
      emit $ Imp.DebugPrint "nonsegmented segBinOp stage 2" Nothing
      tid <-- (i' + 1)
      sComment "Apply main thread reduction" $
        forM_ slugs' $ \slug ->
          sLoopNest (slugShape slug) $ \vec_is -> do
            sComment "load acc params" $
              forM_ (zip (accParams slug) (slugAccs slug)) $ \(p, (acc, acc_is)) ->
              copyDWIMFix (paramName p) [] (Var acc) (acc_is++vec_is)
            sComment "load next params" $
              forM_ (zip (nextParams slug) $ patternElements pat) $ \(p, pe) ->
              copyDWIMFix (paramName p) [] (Var $ patElemName pe) vec_is
            sComment "red body" $
              compileStms mempty (bodyStms $ slugBody slug) $
                forM_ (zip (patternElements pat) (bodyResult $ slugBody slug)) $
                  \(pe, se') -> copyDWIMFix (patElemName pe) vec_is se' []

-- Each thread reduces over the number of segments
-- each of which is done sequentially
-- Maybe we should select the work of the inner loop
-- based on n_segments and dimensions etc.
segmentedReduction :: Pattern MCMem
                   -> SegSpace
                   -> [SegBinOp MCMem]
                   -> DoSegBody
                   -> MulticoreGen ()
segmentedReduction pat space reds kbody = do
  emit $ Imp.DebugPrint "segmented segBinOp " Nothing
  sUnpauseProfiling

  let (is, ns) = unzip $ unSegSpace space
  ns' <- mapM toExp ns
  let inner_bound = last ns'

  tid <- dPrim "tid" $ IntType Int32
  tid' <- toExp $ Var tid

  n_segments <- dPrim "segment_iter" $ IntType Int32
  n_segments' <- toExp $ Var n_segments

  -- Perform sequential reduce on inner most dimension
  fbody <- collect $ do
    emit $ Imp.DebugPrint "segmented segBinOp stage 1" Nothing
    dPrimV_ (segFlat space) tid'
    flat_idx <- dPrimV "flat_idx" (n_segments' * inner_bound)
    flat_idx' <- toExp $ Var flat_idx
    zipWithM_ dPrimV_ is $ unflattenIndex ns' $ Imp.vi32 flat_idx
    sComment "neutral-initialise the accumulators" $
      forM_ reds $ \red->
        forM_ (zip (patternElements pat) (segBinOpNeutral red)) $ \(pe, ne) ->
          sLoopNest (segBinOpShape red) $ \vec_is ->
            copyDWIMFix (patElemName pe) (map Imp.vi32 (init is) ++ vec_is) ne []

    sComment "function main body" $ do
      dScope Nothing $ scopeOfLParams $ concatMap (lambdaParams . segBinOpLambda) reds
      sFor "i" inner_bound $ \_i -> do
        forM_ (zip is $ unflattenIndex ns' $ Imp.vi32 flat_idx) $ uncurry (<--)
        kbody $ \all_red_res -> do
          let red_res' = chunks (map (length . segBinOpNeutral) reds) all_red_res
          forM_ (zip reds red_res') $ \(red, res') ->
            sLoopNest (segBinOpShape red) $ \vec_is -> do

            sComment "load accum" $ do
              let acc_params = take (length (segBinOpNeutral red)) $ (lambdaParams . segBinOpLambda) red
              forM_ (zip acc_params (patternElements pat)) $ \(p, pe) ->
                copyDWIMFix (paramName p) [] (Var $ patElemName pe) (map Imp.vi32 (init is) ++ vec_is)

            sComment "load new val" $ do
              let next_params = drop (length (segBinOpNeutral red)) $ (lambdaParams . segBinOpLambda) red
              forM_ (zip next_params res') $ \(p, (res, res_is)) ->
                copyDWIMFix (paramName p) [] res (res_is ++ vec_is)

            sComment "apply reduction" $ do
              let lbody = (lambdaBody . segBinOpLambda) red
              compileStms mempty (bodyStms lbody) $
                sComment "write back to res" $
                forM_ (zip (patternElements pat) (bodyResult lbody)) $
                  \(pe, se') -> copyDWIMFix (patElemName pe) (map Imp.vi32 (init is) ++ vec_is) se' []
        flat_idx <-- flat_idx' + 1

  let freeVariables = namesToList $ freeIn fbody `namesSubtract`
                                    namesFromList (tid : [n_segments])

  ts <- mapM lookupType freeVariables
  let freeParams = zipWith toParam freeVariables ts

  ntask <- dPrim "num_tasks" $ IntType Int32

  let (body_allocs, fbody') = extractAllocations fbody

  emit $ Imp.Op $ Imp.ParLoop (decideScheduling fbody)
                               ntask n_segments (product $ init ns') freeParams
                              (Imp.MulticoreFunc body_allocs fbody' tid)
                              (Imp.SequentialFunc mempty fbody)



sequentialRed :: [[VName]]
              -> VName
              -> SegSpace
              -> [SegBinOp MCMem]
              -> DoSegBody
              -> MulticoreGen Imp.Code
sequentialRed result_arr flat_idx space reds kbody = do
  let (is, ns) = unzip $ unSegSpace space
  ns' <- mapM toExp ns
  collect $ do
    zipWithM_ dPrimV_ is $ unflattenIndex ns' $ Imp.vi32 flat_idx
    dScope Nothing $ scopeOfLParams $ concatMap (lambdaParams . segBinOpLambda) reds
    kbody $ \all_red_res -> do
      let all_red_res' = segBinOpChunks reds all_red_res
      forM_ (zip3 all_red_res' reds result_arr) $ \(red_res, red, res_arr) -> do
        let (xParams, yParams) = splitAt (length (segBinOpNeutral red)) $ (lambdaParams . segBinOpLambda) red
        sLoopNest (segBinOpShape red) $ \vec_is -> do
          sComment "load acc params" $
            forM_ (zip xParams res_arr) $ \(p, res) ->
              copyDWIMFix (paramName p) [] (Var res) (0 : vec_is)
          sComment "load next params" $
            forM_ (zip yParams red_res) $ \(p, (res, res_is)) ->
              copyDWIMFix (paramName p) [] res (res_is ++ vec_is)
          sComment "sequential red body" $
            compileStms mempty (bodyStms $ (lambdaBody . segBinOpLambda) red) $
                forM_ (zip res_arr (bodyResult $ (lambdaBody . segBinOpLambda) red)) $
                  \(res, se) -> copyDWIMFix res (0 : vec_is) se []