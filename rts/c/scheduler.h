// start of scheduler.h

#ifndef SCHEDULER_H
#define SCHEDULER_H

#define MULTICORE
/* #define MCDEBUG */

#ifdef _WIN32
#include <windows.h>
#elif __APPLE__
#include <sys/sysctl.h>
#else
#include <sys/sysinfo.h>
#endif

static inline int check_err(int errval, int sets_errno, const char *fun, int line,
                            const char *msg, ...)
{
  if (errval) {
    char str[256];
    char errnum[10];
    sprintf(errnum, "%d", errval);
    sprintf(str, "ERROR: %s in %s() at line %d with error code %s\n", msg, fun, line,
            sets_errno ? strerror(errno) : errnum);
    fprintf(stderr, "%s", str);
  }
  return errval;
}

#define CHECK_ERR(err, msg...) check_err(err, 0, __func__, __LINE__, msg)
#define CHECK_ERRNO(err, msg...) check_err(err, 1, __func__, __LINE__, msg)

// returns the number of logical cores
static int num_processors() {
#ifdef _WIN32
/* https://docs.microsoft.com/en-us/windows/win32/api/sysinfoapi/ns-sysinfoapi-system_info */
    SYSTEM_INFO sysinfo;
    GetSystemInfo(&sysinfo);
    int ncores = sysinfo.dwNumberOfProcessors;
    fprintf(stdout, "Found %d cores on your Windows machine\n Is that correct?\n", ncores);
    return ncores;
#elif __APPLE__
    int ncores;
    size_t ncores_size = sizeof(ncores);
    CHECK_ERRNO(sysctlbyname("hw.logicalcpu", &ncores, &ncores_size, NULL, 0),
                "sysctlbyname (hw.logicalcpu)");
    return ncores;
#else // If Linux
  return get_nprocs();
#endif
}

typedef int (*task_fn)(void*, int, int, int);

// A task for the scheduler to execute
struct task {
  const char* name;
  task_fn fn;
  void* args;
  long int iterations;
};


/* A subtask that can be executed by a thread */
struct subtask {
  task_fn fn;
  void* args;
  int start, end;
  int subtask_id;

  // Shared variables across subtasks
  int *counter; // Counter ongoing subtasks
  pthread_mutex_t *mutex;
  pthread_cond_t *cond;
};


struct scheduler {
  struct job_queue q;
  pthread_t *threads; // An array of threads
  int num_threads;

  // Temp fix for error printing
  struct futhark_context* ctx;
};


enum SegOp {
  SegMap,
  SegRed,
};

static inline void *futhark_worker(void* arg) {
  struct scheduler *scheduler = (struct scheduler*) arg;
  while(1) {
    struct subtask *subtask;
    if (job_queue_pop(&scheduler->q, (void**)&subtask) == 0) {
      int err = subtask->fn(subtask->args, subtask->start, subtask->end, subtask->subtask_id);
      if (err != 0) {
        panic(err, futhark_context_get_error(scheduler->ctx));
      }
      CHECK_ERR(pthread_mutex_lock(subtask->mutex), "pthread_mutex_lock");
      (*subtask->counter)--;
      CHECK_ERR(pthread_cond_signal(subtask->cond), "pthread_cond_signal");
      CHECK_ERR(pthread_mutex_unlock(subtask->mutex), "pthread_mutex_unlock");
      free(subtask);
    } else {
       break;
    }
  }
  return NULL;
}



static inline struct subtask* setup_subtask(struct task* task, int subtask_id,
                                            pthread_mutex_t *mutex, pthread_cond_t *cond,
                                            int* counter, int start, int end) {
  struct subtask* subtask = malloc(sizeof(struct subtask));
  if (subtask == NULL) {
    assert(!"malloc failed in setup_subtask");
    return  NULL;
  }
  subtask->fn         = task->fn;
  subtask->args       = task->args;
  subtask->subtask_id = subtask_id;
  subtask->mutex      = mutex;
  subtask->cond       = cond;
  subtask->counter    = counter;
  subtask->start      = start;
  subtask->end        = end;
  return subtask;
}


static inline int scheduler_do_task(struct scheduler *scheduler,
                                    struct task * task,
                                    int *ntask)
{

  assert(scheduler != NULL);
  assert(task != NULL);

#ifdef MCDEBUG
  fprintf(stderr, "starting %s\n", task->name);
  fprintf(stderr, "iterations %ld\n", task->iterations);
#endif
  if (task->iterations == 0) {
    if (ntask != NULL)  *ntask = 0;
    return 0;
  }

  pthread_mutex_t mutex;
  CHECK_ERR(pthread_mutex_init(&mutex, NULL), "pthread_mutex_init");
  pthread_cond_t cond;
  CHECK_ERR(pthread_cond_init(&cond, NULL), "pthread_cond_init");

  int subtask_id = 0;
  int shared_counter = 0;
  int iter_pr_subtask = task->iterations / scheduler->num_threads;
  int remainder = task->iterations % scheduler->num_threads;

  struct subtask *subtask = setup_subtask(task, subtask_id,
                                          &mutex, &cond, &shared_counter,
                                          0, remainder + iter_pr_subtask);
  subtask_id++;

  CHECK_ERR(pthread_mutex_lock(&mutex), "pthread_mutex_lock");
  shared_counter++;
  CHECK_ERR(pthread_mutex_unlock(&mutex), "pthread_mutex_unlock");
  CHECK_ERR(job_queue_push(&scheduler->q, (void*)subtask), "job_queue_push");


  for (int i = remainder + iter_pr_subtask; i < task->iterations; i += iter_pr_subtask)
  {
    struct subtask *subtask = setup_subtask(task, subtask_id,
                                            &mutex, &cond, &shared_counter,
                                            i, i + iter_pr_subtask);
    subtask_id++;

    CHECK_ERR(pthread_mutex_lock(&mutex), "pthread_mutex_lock");
    shared_counter++;
    CHECK_ERR(pthread_mutex_unlock(&mutex), "pthread_mutex_unlock");
    CHECK_ERR(job_queue_push(&scheduler->q, (void*)subtask), "job_queue_push");
  }


  // Join (wait for tasks to finish)
  CHECK_ERR(pthread_mutex_lock(&mutex), "pthread_mutex_lock");
  while (shared_counter != 0) {
    CHECK_ERR(pthread_cond_wait(&cond, &mutex), "pthread_cond_wait");
  }

  if (ntask != NULL) {
    *ntask = subtask_id;
  }

  return 0;
}


#endif


// End of scheduler.h