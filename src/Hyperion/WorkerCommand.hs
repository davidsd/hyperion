{-# LANGUAGE OverloadedRecordDot #-}

-- | How hyperion starts its worker processes. The @workerCommand@ of a
-- 'Hyperion.Config.HyperionStaticConfig' turns each 'WorkerLaunch' into
-- the command that is run on the worker's node, by @sbatch@, by the
-- 'Hyperion.WorkerCpuPool.CommandTransport', or by a hyperion process
-- already on that node.
module Hyperion.WorkerCommand
  ( WorkerLaunch (..)
  , defaultWorkerCommand
  , wrapWorkerCommand
  ) where

import Hyperion.OsPath (OsPath, OsString)

-- | A hyperion worker process about to be started.
data WorkerLaunch = WorkerLaunch
  { launchExecutable :: OsPath
    -- ^ The hyperion executable to run
  , launchArguments  :: [OsString]
    -- ^ The arguments that make the executable run as the worker
    -- (see 'Hyperion.Command.workerArgs')
  } deriving (Eq, Show)

-- | Starts a worker by running the hyperion executable itself.
defaultWorkerCommand :: WorkerLaunch -> (OsString, [OsString])
defaultWorkerCommand launch = (launch.launchExecutable, launch.launchArguments)

-- | Starts a worker by running the given program with the given
-- arguments, followed by the command that the given rule would use. For
-- example,
--
-- > wrapWorkerCommand "/usr/bin/numactl" ["--interleave=all"] defaultWorkerCommand
--
-- runs every worker under @numactl@, which spreads the worker's memory
-- evenly over the NUMA nodes of its machine.
wrapWorkerCommand
  :: OsPath
  -> [OsString]
  -> (WorkerLaunch -> (OsString, [OsString]))
  -> WorkerLaunch
  -> (OsString, [OsString])
wrapWorkerCommand program programArgs rule launch =
  let (command, args) = rule launch
  in (program, programArgs ++ command : args)
