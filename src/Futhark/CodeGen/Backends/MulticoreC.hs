{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
-- | C code generator.  This module can convert a correct ImpCode
-- program to an equivalent C program.
module Futhark.CodeGen.Backends.MulticoreC
  ( compileProg
  , GC.CParts(..)
  , GC.asLibrary
  , GC.asExecutable
  ) where

import Control.Monad


import qualified Language.C.Syntax as C
import qualified Language.C.Quote.OpenCL as C
import Futhark.Error
import Futhark.Representation.ExplicitMemory (Prog, ExplicitMemory)
import Futhark.CodeGen.ImpCode.Multicore
import qualified Futhark.CodeGen.ImpGen.Multicore as ImpGen
import qualified Futhark.CodeGen.Backends.GenericC as GC
import Futhark.MonadFreshNames

compileProg :: MonadFreshNames m => Prog ExplicitMemory
            -> m (Either InternalError GC.CParts)
compileProg =
  traverse (GC.compileProg operations generateContext "" [DefaultSpace] []) <=<
  ImpGen.compileProg
  where operations :: GC.Operations Multicore ()
        operations = GC.defaultOperations
                     { GC.opsCompiler = compileOp
                     , GC.opsCopy = copyMulticoreMemory
                     }

        generateContext = do

          cfg <- GC.publicDef "context_config" GC.InitDecl $ \s ->
            ([C.cedecl|struct $id:s;|],
             [C.cedecl|struct $id:s { int debugging; };|])

          GC.publicDef_ "context_config_new" GC.InitDecl $ \s ->
            ([C.cedecl|struct $id:cfg* $id:s(void);|],
             [C.cedecl|struct $id:cfg* $id:s(void) {
                                 struct $id:cfg *cfg = (struct $id:cfg*) malloc(sizeof(struct $id:cfg));
                                 if (cfg == NULL) {
                                   return NULL;
                                 }
                                 cfg->debugging = 0;
                                 return cfg;
                               }|])

          GC.publicDef_ "context_config_free" GC.InitDecl $ \s ->
            ([C.cedecl|void $id:s(struct $id:cfg* cfg);|],
             [C.cedecl|void $id:s(struct $id:cfg* cfg) {
                                 free(cfg);
                               }|])

          GC.publicDef_ "context_config_set_debugging" GC.InitDecl $ \s ->
             ([C.cedecl|void $id:s(struct $id:cfg* cfg, int flag);|],
              [C.cedecl|void $id:s(struct $id:cfg* cfg, int detail) {
                          cfg->debugging = detail;
                        }|])

          GC.publicDef_ "context_config_set_logging" GC.InitDecl $ \s ->
             ([C.cedecl|void $id:s(struct $id:cfg* cfg, int flag);|],
              [C.cedecl|void $id:s(struct $id:cfg* cfg, int detail) {
                                 /* Does nothing for this backend. */
                                 (void)cfg; (void)detail;
                               }|])

          (fields, init_fields) <- GC.contextContents

          ctx <- GC.publicDef "context" GC.InitDecl $ \s ->
            ([C.cedecl|struct $id:s;|],
             [C.cedecl|struct $id:s {
                          struct job_queue q;
                          typename pthread_t *threads;
                          int num_threads;
                          int detail_memory;
                          int debugging;
                          int profiling;
                          typename lock_t lock;
                          char *error;
                          $sdecls:fields
                        };|])

          GC.publicDef_ "context_new" GC.InitDecl $ \s ->
            ([C.cedecl|struct $id:ctx* $id:s(struct $id:cfg* cfg);|],
             [C.cedecl|struct $id:ctx* $id:s(struct $id:cfg* cfg) {
                 struct $id:ctx* ctx = (struct $id:ctx*) malloc(sizeof(struct $id:ctx));
                 if (ctx == NULL) {
                   return NULL;
                 }
                 if (job_queue_init(&ctx->q, 64, num_processors())) return NULL;
                 ctx->detail_memory = cfg->debugging;
                 ctx->debugging = cfg->debugging;
                 ctx->error = NULL;
                 create_lock(&ctx->lock);
                 $stms:init_fields

                 ctx->threads = calloc(ctx->q.num_workers, sizeof(pthread_t));

                 for (int i = 0; i < ctx->q.num_workers; i++) {
                   if (pthread_create(&ctx->threads[i], NULL, &futhark_worker, &ctx->q) != 0) {
                     fprintf(stderr, "Failed to create thread (%d)\n", i);
                     return NULL;
                   }
                }
                return ctx;
              }|])

          GC.publicDef_ "context_free" GC.InitDecl $ \s ->
            ([C.cedecl|void $id:s(struct $id:ctx* ctx);|],
             [C.cedecl|void $id:s(struct $id:ctx* ctx) {
                 job_queue_destroy(&ctx->q);
                 for (int i = 0; i < ctx->q.num_workers; i++) {
                   if (pthread_join(ctx->threads[i], NULL) != 0) {
                     fprintf(stderr, "pthread_join failed on thread %d", i);
                     return 1;
                   }
                 }
                 free_lock(&ctx->lock);
                 free(ctx);
               }|])

          GC.publicDef_ "context_sync" GC.InitDecl $ \s ->
            ([C.cedecl|int $id:s(struct $id:ctx* ctx);|],
             [C.cedecl|int $id:s(struct $id:ctx* ctx) {
                                 (void)ctx;
                                 return 0;
                               }|])
          GC.publicDef_ "context_get_error" GC.InitDecl $ \s ->
            ([C.cedecl|char* $id:s(struct $id:ctx* ctx);|],
             [C.cedecl|char* $id:s(struct $id:ctx* ctx) {
                                 char* error = ctx->error;
                                 ctx->error = NULL;
                                 return error;
                               }|])

          GC.publicDef_ "context_pause_profiling" GC.InitDecl $ \s ->
            ([C.cedecl|void $id:s(struct $id:ctx* ctx);|],
             [C.cedecl|void $id:s(struct $id:ctx* ctx) {
                         (void)ctx;
                       }|])

          GC.publicDef_ "context_unpause_profiling" GC.InitDecl $ \s ->
            ([C.cedecl|void $id:s(struct $id:ctx* ctx);|],
             [C.cedecl|void $id:s(struct $id:ctx* ctx) {
                         (void)ctx;
                       }|])

copyMulticoreMemory :: GC.Copy Multicore ()
copyMulticoreMemory destmem destidx DefaultSpace srcmem srcidx DefaultSpace nbytes =
  GC.copyMemoryDefaultSpace destmem destidx srcmem srcidx nbytes
copyMulticoreMemory _ _ destspace _ _ srcspace _ =
  error $ "Cannot copy to " ++ show destspace ++ " from " ++ show srcspace


compileStructFields :: C.ToIdent a =>
                       [a] -> [C.Type] -> [C.FieldGroup]
compileStructFields  fargs fctypes =
  [ [C.csdecl|$ty:ty *$id:name;|]| (name, ty) <- zip fargs fctypes]


-- | Sets the field values of the struct
--   Assummes that vnames are fields of the struct
compileSetStructValues :: (C.ToIdent a1, C.ToIdent a2) =>
                           a1 -> [a2] -> [C.Stm]
compileSetStructValues struct vnames =
  [ [C.cstm|$id:struct.$id:name=&$id:name;|] | name <- vnames]


compileGetStructVals :: (C.ToIdent a1, C.ToIdent a2) =>
                         a2 -> [a1] -> [C.Type] -> [C.InitGroup]
compileGetStructVals struct fargs fctypes =
  [ [C.cdecl|$ty:ty $id:name = *$id:struct->$id:name;|]
            | (name, ty) <- zip fargs fctypes ]

paramToCType :: Param -> C.Type
paramToCType t = case t of
               ScalarParam _ pt  -> GC.primTypeToCType pt
               MemParam _ space' -> GC.fatMemType space'

compileOp :: GC.OpCompiler Multicore ()
compileOp (ParLoop ntasks i e (MulticoreFunc params prebody body tid)) = do
  let fctypes = map paramToCType params
  let fargs   = map paramName params
  e' <- GC.compileExp e

  prebody' <- GC.blockScope $ GC.compileCode prebody
  body' <- GC.blockScope $ GC.compileCode body


  fstruct <- GC.multicoreDef "parloop_struct" $ \s ->
     [C.cedecl|struct $id:s {
                 struct futhark_context *ctx;
                 $sdecls:(compileStructFields fargs fctypes)
               };|]

  ftask <- GC.multicoreDef "parloop" $ \s ->
    [C.cedecl|int $id:s(void *args, int start, int end, int $id:tid) {
              struct $id:fstruct *$id:fstruct = (struct $id:fstruct*) args;
              struct futhark_context *ctx = $id:fstruct->ctx;
              $decls:(compileGetStructVals fstruct fargs fctypes)
              int $id:i = start;
              $items:prebody'
              for (; $id:i < end; $id:i++) {
                  $items:body'
              }
              return 0;
           }|]

  GC.decl [C.cdecl|struct $id:fstruct $id:fstruct;|]
  GC.stm [C.cstm|$id:fstruct.ctx = ctx;|]
  GC.stms [C.cstms|$stms:(compileSetStructValues fstruct fargs)|]
  GC.stm [C.cstm|if (scheduler_do_task(&ctx->q, $id:ftask, &$id:fstruct, $exp:e', &$id:ntasks) != 0) {
                     fprintf(stderr, "scheduler failed to do task\n");
                     return 1;
           }|]