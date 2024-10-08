{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE OverloadedRecordDot  #-}
{-# LANGUAGE TypeApplications   #-}

module Hyperion.WorkerCpuPool
  ( CommandTransport (..)
  , defaultCommandTransport
  , NumCPUs(..)
  , SSHError
  , WorkerAddr(..)
  , WorkerCpuPool(..)
  , withWorkerAddr
  , getSlurmAddrs
  , newPool
  , newPoolFromSlurmEnv
  , remoteRunCmd
  ) where

import Control.Concurrent.STM      (atomically, check)
import Control.Concurrent.STM.TVar (TVar, modifyTVar, newTVarIO, readTVar)
import Control.Exception           (Exception)
import Control.Monad               (when)
import Control.Monad.Catch         (MonadMask, bracket, try)
import Control.Monad.IO.Class      (MonadIO, liftIO)
import Data.Aeson                  (FromJSON, ToJSON)
import Data.Binary                 (Binary)
import Data.List.Extra             (maximumOn)
import Data.Map.Strict             (Map)
import Data.Map.Strict             qualified as Map
import Data.Maybe                  (fromMaybe)
import GHC.Generics                (Generic)
import Hyperion.Log                qualified as Log
import Hyperion.Slurm              qualified as Slurm
import Hyperion.Util               (retryRepeated, runCmdLocalAsync, shellEsc)
import System.Exit                 (ExitCode (..))
import System.Process              (proc, readCreateProcessWithExitCode)

-- * General comments
-- $
-- This module defines 'WorkerCpuPool', a datatype that provides a mechanism
-- for @hyperion@ to manage the resources allocated to it by @SLURM@. The only
-- resource that is managed are the CPU's on the allocated nodes. This module
-- works under the assumption that the same number of CPU's has been allocated
-- on all the nodes allocated to the job.
--
-- A 'WorkerCpuPool' is essentially a 'TVar' containing the 'Map' that maps
-- node addresses to the number of CPU's available on that node. The addess can
-- be a remote node or the local node on which 'WorkerCpuPool' is hosted.
--
-- The most important function defined in this module is 'withWorkerAddr' which
-- allocates the requested number of CPUs from the pull on a single node and
-- runs a user function with the address of that node. The allocation mechanism
-- is very simple and allocates CPU's on the worker which has the most idle CPUs.
--
-- We also provide 'remoteRunCmd' for running commands on the nodes via @ssh@ or @srun@.
-- * 'WorkerCpuPool' documentation
-- $
-- | A newtype for the number of available CPUs
newtype NumCPUs =
  NumCPUs Int
  deriving newtype (Eq, Ord, Num)

-- | The 'WorkerCpuPool' type, contaning a map of available CPU resources
data WorkerCpuPool = WorkerCpuPool
  { cpuMap :: TVar (Map WorkerAddr NumCPUs)
  }

-- | 'newPool' creates a new 'WorkerCpuPool' from a 'Map'.
newPool :: Map WorkerAddr NumCPUs -> IO WorkerCpuPool
newPool cpus = WorkerCpuPool <$> newTVarIO cpus

-- | A 'WorkerAddr' representing a node address. Can be a remote node or the local node
data WorkerAddr
  = LocalHost String
  | RemoteAddr String
  deriving (Eq, Ord, Show, Generic, Binary, FromJSON, ToJSON)

-- | Reads the system environment to obtain the list of nodes allocated to the job.
-- If the local node is in the list, then records it too, as 'LocalHost'.
getSlurmAddrs :: IO [WorkerAddr]
getSlurmAddrs = do
  jobNodes <- Slurm.getJobNodes
  mHeadNode <- Slurm.lookupHeadNode
  return $ map (toAddr mHeadNode) jobNodes
  where
    toAddr mh n =
      if mh == Just n
        then LocalHost n
        else RemoteAddr n

-- | Reads the system environment to determine the number of CPUs available on
-- each node (the same number on each node), and creates a new 'WorkerCpuPool'
-- for the @['WorkerAddr']@ assuming that all CPUs are available.
newPoolFromSlurmEnv :: [WorkerAddr] -> IO WorkerCpuPool
newPoolFromSlurmEnv nodes = do
  when (null nodes) (Log.throwError "Empty node list")
  cpusPerNode <- fmap NumCPUs Slurm.getNTasksPerNode
  newPool $ Map.fromList $ zip nodes (repeat cpusPerNode)

-- | Finds the worker with the most available CPUs and runs the given
-- routine with the address of that worker. Blocks if the number of
-- available CPUs is less than the number requested.
withWorkerAddr ::
     (MonadIO m, MonadMask m)
  => WorkerCpuPool
  -> NumCPUs
  -> (WorkerAddr -> m a)
  -> m a
withWorkerAddr pool cpus go =
  bracket (liftIO getWorkerAddr) (liftIO . replaceWorkerAddr) go
  where
    getWorkerAddr =
      atomically $ do
        workers <- readTVar pool.cpuMap
      -- find the worker with the largest number of cpus
        let (addr, availCpus) = maximumOn snd $ Map.toList workers
      -- If not enough cpus are available, retry
        check (availCpus >= cpus)
      -- subtract the requested cpus from the worker's total
        modifyTVar pool.cpuMap (Map.adjust (subtract cpus) addr)
        return addr
    replaceWorkerAddr addr =
      atomically
        $
        -- add back the requested cpus to the worker's total
         modifyTVar pool.cpuMap (Map.adjust (+ cpus) addr)

-- * 'remoteRunCmd' documentation
-- $
-- Type for @ssh@ errors. The 'String's are 'stdout' and 'stderr' of @ssh@.
data SSHError =
  SSHError String (ExitCode, String, String)
  deriving (Show, Exception)

-- | The type for the command used in order to run processes on
-- another node. Can be @ssh$ or @srun$ with custom or default
-- arguments. If a 'Just' value, then the first 'String' gives the
-- name of @ssh@ or@srun@ executable, e.g. @\"ssh\"@, and the list of
-- 'String's gives the options to pass to the executable. For example,
-- with 'CommandTransport' given by @SSH $ Just (\"XX\", [\"-a\",
-- \"-b\"])@, @ssh@ is run as
--
-- > XX -a -b <addr> <command>
--
-- where @\<addr\>@ is the remote address and @\<command\>@ is the command we need
-- to run there.
--
-- For @ssh@, the value of 'Nothing' is equivalent to using
--
-- > ssh -f -o "UserKnownHostsFile /dev/null" <addr> <command>
--
-- We need @-o \"...\"@ option to deal with host key verification
-- failures. We use @-f@ to force @ssh@ to go to the background before executing
-- the @sh@ call. This allows for a faster return from 'readCreateProcessWithExitCode'.
--
-- Note that @\"UserKnownHostsFile \/dev\/null\"@ doesn't seem to work on Helios.
-- Using instead @\"StrictHostKeyChecking=no\"@ seems to work.
--
-- TODO: add @srun@ documentation
data CommandTransport
  = SSH (Maybe (String, [String]))
  | SRun (Maybe (String, [String]))
  deriving (Eq, Ord, Show, Generic, Binary, FromJSON, ToJSON)

-- | Default CommandTransport. Uses SSH as
--
-- > ssh -f -o "UserKnownHostsFile /dev/null" <addr> <command>
--
defaultCommandTransport :: CommandTransport
defaultCommandTransport = SSH Nothing

-- | Runs a given command on remote host (with address given by the first 'String') with the
-- given arguments via @ssh@ using the 'CommandTransport'. Makes at most 10 attempts via 'retryRepeated'.
-- If fails, propagates 'SSHError' outside.
--
-- @ssh@ needs to be able to authenticate on the remote
-- node without a password. In practice you will probably need to set up public
-- key authentiticaion.
--
-- @ssh@ is invoked to run @sh@ that calls @nohup@ to run the supplied command
-- in background.
remoteRunCmd :: String -> CommandTransport -> (String, [String]) -> IO ()
remoteRunCmd addr (SSH sshCmd) (cmd, args) =
  retryRepeated 10 (try @IO @SSHError) $ do
    result@(exit, _, _) <- readCreateProcessWithExitCode (proc ssh sshArgs) ""
    case exit of
      ExitSuccess -> return ()
      _           -> Log.throw (SSHError addr result)
  where
    (ssh, sshOpts) = fromMaybe defaultCmd sshCmd
    sshArgs =
      sshOpts
        ++ [addr, shellEsc "sh" ["-c", shellEsc "nohup" (cmd : args) ++ " &"]]
    -- update the haddock above if changing this default.
    defaultCmd = ("ssh", ["-f", "-o", "UserKnownHostsFile /dev/null"])
remoteRunCmd addr (SRun srunCmd) (cmd, args) = runCmdLocalAsync (srun, srunArgs)
  where
    (srun, srunOpts) = fromMaybe defaultCmd srunCmd
    srunArgs = srunOpts ++ ["--nodelist", addr, cmd] ++ args
    -- update the haddock above if changing this default.
    defaultCmd =
      ( "srun"
      , ["--external-launcher", "--nodes=1", "--ntasks=1", "--immediate"])
