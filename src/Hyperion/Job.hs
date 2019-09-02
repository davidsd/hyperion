{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StaticPointers             #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}

module Hyperion.Job where

import           Control.Distributed.Process hiding (try)
import           Control.Lens                (lens)
import           Control.Monad.Catch         (try)
import           Control.Monad.Cont          (ContT (..), runContT)
import           Control.Monad.Except
import           Control.Monad.Reader
import           Data.Binary                 (Binary)
import qualified Data.Map                    as Map
import           Data.Maybe                  (catMaybes)
import qualified Data.Text                   as T
import           Data.Typeable               (Typeable)
import           GHC.StaticPtr               (StaticPtr)
import           Hyperion.Cluster
import           Hyperion.Command            (hyperionWorkerCommand)
import qualified Hyperion.Database           as DB
import           Hyperion.HasWorkers         (HasWorkerLauncher (..),
                                              remoteBind)
import qualified Hyperion.Log                as Log
import           Hyperion.Remote
import           Hyperion.Slurm              (JobId (..))
import qualified Hyperion.Slurm              as Slurm
import           Hyperion.Util               (myExecutable)
import           Hyperion.WorkerCpuPool      (NumCPUs (..), SSHError, WorkerAddr)
import qualified Hyperion.WorkerCpuPool      as WCP
import           System.FilePath.Posix       ((<.>), (</>))
import           System.Process              (createProcess, proc)

data JobEnv = JobEnv
  { jobDatabaseConfig :: DB.DatabaseConfig
  , jobNodeCpus       :: NumCPUs
  , jobTaskCpus       :: NumCPUs
  , jobProgramInfo    :: ProgramInfo
  , jobTaskLauncher   :: NumCPUs -> WorkerLauncher JobId
  }

instance DB.HasDB JobEnv where
  dbConfigLens = lens get set
    where
      get = jobDatabaseConfig
      set cfg databaseConfig' = cfg { jobDatabaseConfig = databaseConfig' }

instance HasWorkerLauncher JobEnv where
  toWorkerLauncher JobEnv{..} = jobTaskLauncher jobTaskCpus

type Job = ReaderT JobEnv Process

setTaskCpus :: NumCPUs -> JobEnv -> JobEnv
setTaskCpus n cfg = cfg { jobTaskCpus = n }

runJobLocal :: ProgramInfo -> Job a -> Process a
runJobLocal programInfo go = do
  dbConfig <- liftIO $ dbConfigFromProgramInfo programInfo
  nodes <- liftIO WCP.getSlurmAddrs
  nodeCpus <- liftIO Slurm.getNTasksPerNode
  let logDir = programLogDir programInfo </> "workers" </> "workers"
  withPoolLauncher logDir nodes $ \poolLauncher -> do
    let cfg = JobEnv
          { jobDatabaseConfig = dbConfig
          , jobNodeCpus       = NumCPUs nodeCpus
          , jobTaskCpus       = NumCPUs 1
          , jobTaskLauncher   = poolLauncher
          , jobProgramInfo    = programInfo
          }
    runReaderT go cfg

workerLauncherWithRunCmd
  :: MonadIO m
  => FilePath
  -> ((String, [String]) -> Process ())
  -> m (WorkerLauncher JobId)
workerLauncherWithRunCmd logDir runCmd = liftIO $ do
  hyperionExec <- myExecutable
  let
    withLaunchedWorker :: forall b . NodeId -> ServiceId -> (JobId -> Process b) -> Process b
    withLaunchedWorker nodeId serviceId goJobId = do
      let jobId = JobByName (serviceIdToText serviceId)
          logFile = logDir </> T.unpack (serviceIdToText serviceId) <.> "log"
      runCmd (hyperionWorkerCommand hyperionExec nodeId serviceId logFile)
      goJobId jobId
    connectionTimeout = Nothing
    workerRetries = 0
  return WorkerLauncher{..}

withNodeLauncher
  :: FilePath
  -> WorkerAddr
  -> (Maybe (WorkerAddr, WorkerLauncher JobId) -> Process a)
  -> Process a
withNodeLauncher logDir addr' go = case addr' of
  WCP.RemoteAddr addr -> do
    sshLauncher <- workerLauncherWithRunCmd logDir (liftIO . WCP.sshRunCmd addr)
    eitherResult <- try @Process @SSHError $ do
      withRemoteRunProcess sshLauncher $ \remoteRunNode ->
        let runCmdOnNode = remoteRunNode <=< applyRemoteStatic (static (remoteFnIO runCmdLocal))
        in workerLauncherWithRunCmd logDir runCmdOnNode >>= \launcher ->
        go (Just (addr', launcher))
    case eitherResult of
      Right result -> return result
      Left err -> do
        Log.warn "Couldn't start launcher" err
        go Nothing
  WCP.LocalHost _ -> do
    launcher <- workerLauncherWithRunCmd logDir (liftIO . runCmdLocalQuiet)
    go (Just (addr', launcher))
  where
    runCmdLocalQuiet :: (String, [String]) -> IO ()
    runCmdLocalQuiet (cmd, args) =
      void $ createProcess $ proc cmd args
    runCmdLocal c = do
      Log.info "Running command" c
      runCmdLocalQuiet c

withPoolLauncher
  :: FilePath
  -> [WorkerAddr]
  -> ((NumCPUs -> WorkerLauncher JobId) -> Process a)
  -> Process a
withPoolLauncher logDir addrs' go = flip runContT return $ do
  mLaunchers <- mapM (ContT . withNodeLauncher logDir) addrs'
  let launcherMap = Map.fromList (catMaybes mLaunchers)
      addrs = Map.keys launcherMap
  workerCpuPool <- liftIO (WCP.newJobPool addrs)
  Log.info "Started worker launchers at" addrs
  lift $ go $ \nCpus -> WorkerLauncher
    { withLaunchedWorker = \nodeId serviceId goJobId ->
        WCP.withWorkerAddr workerCpuPool nCpus $ \addr ->
        withLaunchedWorker (launcherMap Map.! addr) nodeId serviceId goJobId
    , connectionTimeout = Nothing
    , workerRetries     = 0
    }

remoteFnJob
  :: (Binary a, Typeable a, Binary b, Typeable b)
  => (a -> Job b)
  -> RemoteFunction (a, ProgramInfo) b
remoteFnJob f = remoteFn $ \(a, programInfo) -> do
  runJobLocal programInfo (f a)

remoteBindJob
  :: (Binary a, Typeable a, Binary b, Typeable b)
  => Cluster a
  -> StaticPtr (RemoteFunction (a, ProgramInfo) b)
  -> Cluster b
remoteBindJob ma k = do
  programInfo <- asks clusterProgramInfo
  fmap (\a -> (a, programInfo)) ma `remoteBind` k

remoteEvalJob
  :: (Binary a, Typeable a, Binary b, Typeable b)
  => StaticPtr (RemoteFunction (a, ProgramInfo) b)
  -> a
  -> Cluster b
remoteEvalJob k a = return a `remoteBindJob` k
