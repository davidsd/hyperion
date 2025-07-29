{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Hyperion.Command where

import Data.Text           qualified as Text
import Hyperion.Worker     (Service (..), decodeService, encodeService)
import Options.Applicative (Parser, ReadM, eitherReader, help, long, metavar,
                            option, strOption)

-- Note: The argument list in hyperionWorkerCommand and the workerOpts
-- parser must be kept in sync.

-- | Haskell representation of arguments passed to the worker process.
data Worker = Worker
  { workerService :: Service
  , workerLogFile :: FilePath
  } deriving Show

serviceReader :: ReadM Service
serviceReader = eitherReader (decodeService . Text.pack)

serviceArg :: String
serviceArg = "service"

logFileArg :: String
logFileArg = "logFile"

-- | Parses worker command-line arguments. Essentially inverse to 'hyperionWorkerCommand'.
workerOpts :: Parser Worker
workerOpts = do
  workerService <- option serviceReader
    (long serviceArg
      <> metavar "SERVICE"
      <> help "Service on master process (binary encoded)")
  workerLogFile <- strOption
    (long logFileArg
      <> metavar "PATH"
      <> help "Path for worker log file")
  return Worker{..}

-- | Returns the @(command, [arguments])@ to run the worker process
hyperionWorkerCommand :: FilePath -> Service -> FilePath -> (String, [String])
hyperionWorkerCommand hyperionExecutable service logFile =
  ( hyperionExecutable
  , [ "worker"
    , "--"<>serviceArg, Text.unpack $ encodeService service
    , "--"<>logFileArg, logFile
    ]
  )
