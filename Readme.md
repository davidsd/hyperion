About 
-----

Hyperion is a Haskell framework for running concurrent computations on
an [HPC cluster](https://en.wikipedia.org/wiki/High-performance_computing) [1] [2], based
on the [distributed-process library](http://hackage.haskell.org/package/distributed-process-0.7.4). It is targeted at clusters running the [Slurm workload manager](https://slurm.schedmd.com/documentation.html). However, it can in principle be modified to use an arbitrary resource manager.

See the `example` directory for usage examples. The example `example/src-root-search/Main.hs` demonstrates most of the main features.

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
  
Documentation
-------------

Documentation is available at
[https://davidsd.github.io/hyperion/](https://davidsd.github.io/hyperion/).
