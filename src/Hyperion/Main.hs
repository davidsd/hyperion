{-# LANGUAGE ApplicativeDo       #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Hyperion.Main where

import           Control.Concurrent        (forkIO, killThread)
import           Control.Monad             (unless)
import           Data.Maybe                (isJust)
import           Hyperion.Cluster          (Cluster, ClusterEnv (..),
                                            ProgramInfo (..), runCluster,
                                            runDBWithProgramInfo)
import           Hyperion.Command          (Worker (..), workerOpts)
import           Hyperion.Config           (HyperionConfig (..), newClusterEnv)
import qualified Hyperion.Database         as DB
import           Hyperion.HoldServer       (runHoldServer)
import qualified Hyperion.Log              as Log
import           Hyperion.Remote           (addressToNodeId,
                                            runProcessLocallyDefault, worker)
import           Options.Applicative
import           System.Console.Concurrent (withConcurrentOutput)
import           System.Directory          (removeFile)
import           System.Environment        (getEnvironment)
import           System.FilePath.Posix     ((</>))
import           System.Posix.Process      (getProcessID)

data HyperionOpts a = HyperionMaster a | HyperionWorker Worker

hyperionOpts :: Parser a -> Parser (HyperionOpts a)
hyperionOpts programOpts = subparser $ mconcat
  [ command "worker" $
    info (helper <*> (HyperionWorker <$> workerOpts)) $
    progDesc "Run a worker process. Usually this is run automatically."
  , command "master" $
    info (helper <*> (HyperionMaster <$> programOpts)) $
    progDesc "Run a master process"
  ]

opts :: Parser a -> ParserInfo (HyperionOpts a)
opts programOpts = info (helper <*> hyperionOpts programOpts) fullDesc

hyperionMain
  :: Show a
  => Parser a
  -> (a -> HyperionConfig)
  -> (a -> Cluster ())
  -> IO ()
hyperionMain programOpts mkHyperionConfig clusterProgram = withConcurrentOutput $
  execParser (opts programOpts) >>= \case
  HyperionWorker Worker{..} -> do
    Log.redirectToFile workerLogFile
    Log.info "Starting service" workerService
    Log.info "Environment" =<< getEnvironment
    runProcessLocallyDefault
      (worker (addressToNodeId workerMasterAddress) workerService)
  HyperionMaster args -> do
    let hyperionConfig = mkHyperionConfig args
    (clusterEnv@ClusterEnv{..}, hyperionExecutable, holdMap) <- newClusterEnv hyperionConfig
    let progId = programId clusterProgramInfo
        masterLogFile = programLogDir clusterProgramInfo </> "master.log"
    pid <- getProcessID
    let logMasterInfo = do
          Log.info "Program id" progId
          Log.info "Process id" pid
          Log.info "Program arguments" args
          Log.info "Using database" (programDatabase clusterProgramInfo)
          Log.info "Running hold server on port" 11132
    logMasterInfo
    Log.info "Logging to" masterLogFile
    Log.flush
    Log.redirectToFile masterLogFile
    logMasterInfo
    runDBWithProgramInfo clusterProgramInfo DB.createKeyValTable
    holdServerThread <- forkIO $ runHoldServer holdMap
    runCluster clusterEnv (clusterProgram args)
    unless (isJust (hyperionCommand hyperionConfig)) $ removeFile hyperionExecutable
    killThread holdServerThread
    Log.info "Finished" progId

