{-# LANGUAGE ApplicativeDo       #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings   #-}

module Hyperion.Main where

import Control.Monad             (unless)
import Control.Monad.Catch       (SomeException, try)
import Data.Maybe                (isJust)
import Hyperion.Cluster          (Cluster, ClusterEnv (..), ProgramInfo (..),
                                  newClusterEnv, runCluster,
                                  runDBWithProgramInfo)
import Hyperion.Command          (Worker (..), workerOpts)
import Hyperion.Config           (HyperionConfig (..),
                                  HyperionStaticConfig (..))
import Hyperion.Database         qualified as DB
import Hyperion.Log              qualified as Log
import Hyperion.Remote           (runProcessLocalWithRT)
import Hyperion.Server           (newServerState, withHyperionServer)
import Hyperion.Util             (logMemoryUsage)
import Hyperion.Worker           (initWorkerRemoteTable, runWorker,
                                  serviceNodeId)
import Options.Applicative
import System.Console.Concurrent (withConcurrentOutput)
import System.Directory          (removeFile)
import System.Environment        (getEnvironment)
import System.FilePath.Posix     ((<.>))
import System.Posix.Process      (getProcessID)
import System.Posix.Signals      (Handler (..), installHandler, raiseSignal,
                                  sigINT, sigTERM)

-- | The type for command-line options to 'hyperionMain'. Here @a@ is
-- the type for program-specific options.  In practice we want @a@ to
-- be an instance of 'Show'
data HyperionOpts a =
    HyperionMaster a      -- ^ Constructor for the case of a master
                          -- process, holds program-specific options
  | HyperionWorker Worker -- ^ Constructor for the case of a worker
                          -- process, holds 'Worker' which is parsed
                          -- by 'workerOpts'


-- | Main command-line option parser for 'hyperionMain'.  Returns a
-- 'Parser' that supports commands "worker" and "master", and uses
-- 'workerOpts' or the supplied parser, respectively, to parse the
-- remaining options
hyperionOpts
  :: Parser a -- ^ 'Parser' for program-specific options
  -> Parser (HyperionOpts a)
hyperionOpts programOpts = subparser $ mconcat
  [ command "worker" $
    info (helper <*> (HyperionWorker <$> workerOpts)) $
    progDesc "Run a worker process. Usually this is run automatically."
  , command "master" $
    info (helper <*> (HyperionMaster <$> programOpts)) $
    progDesc "Run a master process"
  ]

-- | Same as 'hyperionOpts' but with added @--help@ option and wrapped
-- into 'ParserInfo' (by adding program description).  This now can be
-- used in 'execParser' from "Options.Applicative".
opts :: Parser a -> ParserInfo (HyperionOpts a)
opts programOpts = info (helper <*> hyperionOpts programOpts) fullDesc

-- | 'hyperionMain' produces an @'IO' ()@ action that runs @hyperion@ and can be
-- assigned to @main@. It performs the following actions
--
--  1. If command-line arguments start with command @master@ then
--
--      - Uses the supplied parser to parse the remaining options into type @a@
--      - Uses the supplied function to extract 'HyperionConfig' from @a@
--      - The data in 'HyperionConfig' is then used for all following actions
--      - Depending on 'HyperionConfig', extra actions may be performed, see 'newClusterEnv'.
--      - Starts a log in 'stderr', and then redirects it to a file
--      - Starts a hold server from "Hyperion.Server"
--      - Uses 'DB.setupKeyValTable' to setup a "Hyperion.Database.KeyValMap" in the program database
--      - Runs the supplied @'Cluster' ()@ action
--      - Cleans up the copy of the executable, if exists (see 'newClusterEnv').
--
--  2. If command-line arguments start with command @worker@ then
--
--      - Extracts 'Worker' from the rest of the command-line args.
--      - Logs 'ServiceId' of the worker and the system environment to worker log file.
--      - Runs @'worker' (...) :: 'Process' ()@ that connects to the master and waits for a
--        'Hyperion.Remote.ShutDown' message (see 'worker' for details).
--        While waiting, the master can run computations on the node. Low-level
--        functions for this are implemented in "Hyperion.Remote", and some
--        higher-level functions in "Hyperion.HasWorkers"
hyperionMain
  :: Show a
  => Parser a
  -> (a -> HyperionConfig)
  -> HyperionStaticConfig
  -> (a -> Cluster ())
  -> IO ()
hyperionMain programOpts mkHyperionConfig hyperionStaticConfig clusterProgram = withConcurrentOutput $
  execParser (opts programOpts) >>= \case
  HyperionWorker worker -> do
    Log.redirectToFile worker.workerLogFile
    Log.info "Starting service" worker.workerService
    Log.info "Environment" =<< getEnvironment
    let masterNodeId = serviceNodeId worker.workerService
    runProcessLocalWithRT (hostNameStrategy hyperionStaticConfig)
      (initWorkerRemoteTable hyperionStaticConfig (Just masterNodeId))
      (runWorker worker.workerService)
    logMemoryUsage
  HyperionMaster args -> do
    let hyperionConfig = mkHyperionConfig args

    -- If we recieve a SIGTERM or SIGINT signal, log it once and
    -- re-raise it (causing the program to exit)
    let
      handleSignal name s = CatchOnce $ do
        Log.info "Received signal" (name :: String)
        raiseSignal s
    installHandler sigTERM (handleSignal "SIGTERM" sigTERM) Nothing
    installHandler sigINT  (handleSignal "SIGINT"  sigINT)  Nothing

    serverState <- newServerState
    withHyperionServer serverState $ \serverPort -> do
      (clusterEnv, hyperionExecutable) <-
        newClusterEnv hyperionConfig hyperionStaticConfig serverState serverPort
      let
        programInfo = clusterEnv.clusterProgramInfo
        masterLogFile = programInfo.programLogDir <.> "log"
      pid <- getProcessID
      let logMasterInfo = do
            Log.info "Program id" programInfo.programId
            Log.info "Process id" pid
            Log.info "Program arguments" args
            Log.info "Using database" programInfo.programDatabase
            Log.info "Running server on port" serverPort
      Log.rawText "--------------------------------------------------------------------------------\n"
      logMasterInfo
      Log.info "Logging to" masterLogFile
      Log.flush
      Log.redirectToFile masterLogFile
      logMasterInfo
      runDBWithProgramInfo programInfo DB.setupKeyValTable
      try (runCluster clusterEnv (clusterProgram args)) >>= \case
        Left (e :: SomeException) -> Log.throw e
        Right () -> do
          unless (isJust (hyperionCommand hyperionConfig)) $
            removeFile hyperionExecutable
          Log.info "Finished" programInfo.programId
    logMemoryUsage
