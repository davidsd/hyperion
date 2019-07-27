{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Hyperion.Command where

import           Control.Distributed.Process
import           Data.Monoid                 ((<>))
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import           Hyperion.Remote
import           Options.Applicative

-- Note: The argument list in hyperionWorkerCommand and the workerOpts
-- parser must be kept in sync.

data Worker = Worker
  { workerMasterAddress :: Text
  , workerService       :: ServiceId
  , workerLogFile       :: FilePath
  } deriving Show

workerOpts :: Parser Worker
workerOpts = do
  workerMasterAddress <- T.pack <$>
    strOption (long "address"
               <> metavar "HOST:PORT"
               <> help "Address of the master process")
  workerService <- ServiceId <$>
    strOption (long "service"
               <> metavar "SERVICENAME"
               <> help "Name of service on master process")
  workerLogFile <-
    strOption (long "logFile"
               <> metavar "PATH"
               <> help "Path for worker log file")
  return Worker{..}

hyperionWorkerCommand :: FilePath -> NodeId -> ServiceId -> FilePath -> (String, [String])
hyperionWorkerCommand hyperionExecutable masterNode masterService logFile =
  (hyperionExecutable, map T.unpack args)
  where
    args = [ "worker"
           , "--address", nodeIdToAddress masterNode
           , "--service", serviceIdToText masterService
           , "--logFile", T.pack logFile
           ]
