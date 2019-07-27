About 
-----

Hyperion is a Haskell framework for running concurrent computations on
an [HPC cluster](https://en.wikipedia.org/wiki/High-performance_computing) [1] [2], based
on the [distributed-process library](http://hackage.haskell.org/package/distributed-process-0.7.4). It is targeted at clusters running the [Slurm workload manager](https://slurm.schedmd.com/documentation.html). However, it can in principle be modified to use an arbitrary resource manager.

The basic idea is to define a `Monad`

    newtype Cluster a = Cluster { ... }

together with a remote evaluation function

    remoteEval :: StaticPtr (RemoteFunction a b) -> a -> Cluster b

that allows one to evaluate a function on a remote machine. Here,
`RemoteFunction a b` is a function `a -> IO b` together with
information about how to serialize the types `a` and `b`. `remoteEval`
automatically takes care of submitting a job to the queue, waiting for
the job to start, sending the input of type `a` to the worker node,
and receiving the result of type `b`.

`Monad`s let you sequence computations. To perform computations
concurrently, we provide an `Applicative` in the style of the
[async library](http://hackage.haskell.org/package/async-2.2.1)

    newtype Concurrently m a = Concurrently { runConcurrently :: m a }

together an instance `Applicative (Concurrently Cluster)` and utilities like

```haskell
mapConcurrently
  :: (Applicative (Concurrently m), Traversable t)
  => (a -> m b) -> t a -> m (t b)
mapConcurrently f = runConcurrently . traverse (Concurrently . f)
```

As an `Applicative`, `Concurrently Cluster` lets us use all the features in the
[Control.Applicative](http://hackage.haskell.org/package/base-4.12.0.0/docs/Control-Applicative.html)
module and others based off of it. For example [traverse](http://hackage.haskell.org/package/base-4.12.0.0/docs/Data-Traversable.html#v:traverse)
is a basic function in the Haskell standard library.

This lets us write code like

```haskell
myComputation computeInput inputList = do
  resultList1 <- 
    -- Use 1 node and 1 core for each job
    local (setJobType (MPIJob 1 1)) $
    -- Submit a job for each element of inputList, run computeInput
    -- on each remote machine and collect the results
    mapConcurrently (remoteEval computeInput) inputList
  -- Submit a giant job with 32 nodes and 32 cores per node, run a
  -- big expensive computation on the remote machines and collect
  -- the result.
  local (setJobType (MPIJob 32 32)) $
    remoteEval bigExpensiveFunction resultList1

lotsOfMyComputation computeInput manyInputLists =
  -- Concurrently run a copy of myComputation for each inputList
  -- inside manyInputLists and collect the results. For example, if
  -- manyInputLists = [[1,2],[3,4],[5,6]], overall this will submit
  -- 6 one-core jobs and 3 1024-core jobs.
  mapConcurrently (myComputation computeInput) manyInputLists
```
      
Thus, we abstract over the cluster, allowing one to program as if
there were a single giant machine.

TODO: Describe the `Job` monad.

[1]: The design of Hyperion was heavily inspired by [Haxl](https://github.com/facebook/Haxl),
although unlike Haxl, we choose not to break the standard relationship between `ap` and `<*>`.

[2]: Hyperion is named after the (now defunct) Hyperion cluster at the [IAS](https://www.ias.edu/).

Author
------

David Simmons-Duffin (dsd AT caltech DOT edu) 2013-2019

Installation and Running
------------------------

- Run `stack build`

- Run an example computation: (TODO)
  
