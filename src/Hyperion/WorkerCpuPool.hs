{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE TypeApplications           #-}

module Hyperion.WorkerCpuPool where

import           Control.Concurrent.STM      (atomically, check)
import           Control.Concurrent.STM.TVar (TVar, modifyTVar, newTVarIO,
                                              readTVar, readTVarIO)
import           Control.Exception           (Exception)
import           Control.Monad               (when)
import           Control.Monad.Catch         (MonadMask, bracket, try)
import           Control.Monad.IO.Class      (MonadIO, liftIO)
import           Data.List.Extra             (maximumOn)
import           Data.Map.Strict             (Map)
import qualified Data.Map.Strict             as Map
import qualified Hyperion.Log                as Log
import qualified Hyperion.Slurm              as Slurm
import           Hyperion.Util               (retryRepeated, shellEsc)
import           System.Exit                 (ExitCode (..))
import           System.Process              (proc)
import           System.Process              (readCreateProcessWithExitCode)

newtype NumCPUs = NumCPUs Int
  deriving newtype (Eq, Ord, Num)

data WorkerCpuPool = WorkerCpuPool { cpuMap :: TVar (Map WorkerAddr NumCPUs) }

mkWorkerCpuPool :: Map WorkerAddr NumCPUs -> IO WorkerCpuPool
mkWorkerCpuPool cpus = do
  cpuMap <- newTVarIO cpus
  return WorkerCpuPool{..}

getAddrs :: WorkerCpuPool -> IO [WorkerAddr]
getAddrs WorkerCpuPool{..} = fmap Map.keys (readTVarIO cpuMap)

data WorkerAddr = LocalHost String | RemoteAddr String
  deriving (Eq, Ord, Show)

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

newJobPool :: [WorkerAddr] -> IO WorkerCpuPool
newJobPool nodes = do
  when (null nodes) (Log.throwError "Empty node list")
  cpusPerNode <- fmap NumCPUs Slurm.getNTasksPerNode
  mkWorkerCpuPool $ Map.fromList $ zip nodes (repeat cpusPerNode)

-- | Finds the worker with the most available CPUs and runs the given
-- routine with the address of that worker. Blocks if the number of
-- available CPUs is less than the number requested.
withWorkerAddr
  :: (MonadIO m, MonadMask m)
  => WorkerCpuPool
  -> NumCPUs
  -> (WorkerAddr -> m a)
  -> m a
withWorkerAddr WorkerCpuPool{..} cpus go =
  bracket (liftIO getWorkerAddr) (liftIO . replaceWorkerAddr) go
  where
    getWorkerAddr = atomically $ do
      workers <- readTVar cpuMap
      -- find the worker with the largest number of cpus
      let (addr, availCpus) = maximumOn snd $ Map.toList workers
      -- If not enough cpus are available, retry
      check (availCpus >= cpus)
      -- subtract the requested cpus from the worker's total
      modifyTVar cpuMap (Map.adjust (subtract cpus) addr)
      return addr
    replaceWorkerAddr addr = atomically $
        -- add back the requested cpus to the worker's total
        modifyTVar cpuMap (Map.adjust (+cpus) addr)

data SSHError = SSHError String (ExitCode, String, String)
  deriving (Show, Exception)

sshRunCmd :: String -> (String, [String]) -> IO ()
sshRunCmd addr (cmd, args) = retryRepeated 10 (try @IO @SSHError) $ do
  result@(exit, _, _) <- readCreateProcessWithExitCode (proc "ssh" sshArgs) ""
  case exit of
    ExitSuccess -> return ()
    _           -> Log.throw (SSHError addr result)
  where
    sshArgs = [ "-f"
              , "-o"
              , "UserKnownHostsFile /dev/null"
              , addr
              , shellEsc "sh"
                [ "-c"
                , shellEsc "nohup" (cmd : args)
                  ++ " &"
                ]
              ]
