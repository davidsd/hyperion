-- | How hyperion starts its worker processes. The @workerCommand@ of a
-- 'Hyperion.Config.HyperionStaticConfig' turns the command that runs the
-- hyperion executable as a worker, @(executable, arguments)@, into the
-- command that is run on the worker's node, by @sbatch@, by the
-- 'Hyperion.WorkerCpuPool.CommandTransport', or by a hyperion process
-- already on that node.
module Hyperion.WorkerCommand
  ( defaultWorkerCommand
  , wrapWorkerCommand
  ) where

import Hyperion.OsPath (OsPath, OsString)

-- | Starts a worker by running the hyperion executable itself.
defaultWorkerCommand :: (OsString, [OsString]) -> (OsString, [OsString])
defaultWorkerCommand = id

-- | Starts a worker by running the given program with the given
-- arguments, followed by the worker's command. For example,
--
-- > wrapWorkerCommand "/usr/bin/numactl" ["--interleave=all"]
--
-- runs every worker under @numactl@, which spreads the worker's memory
-- evenly over the NUMA nodes of its machine. Compose with '.' to apply
-- several wrappers.
wrapWorkerCommand
  :: OsPath
  -> [OsString]
  -> (OsString, [OsString])
  -> (OsString, [OsString])
wrapWorkerCommand program programArgs (command, args) =
  (program, programArgs ++ command : args)
