{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Hyperion.Command where

import Data.Text           qualified as T
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
serviceReader = eitherReader $ \s -> decodeService (T.pack s)

-- | Parses worker command-line arguments. Essentially inverse to 'hyperionWorkerCommand'.
workerOpts :: Parser Worker
workerOpts = do
  workerService <- option serviceReader
    (long "service"
      <> metavar "SERVICE"
      <> help "Service on master process (binary encoded)")
  workerLogFile <- strOption
    (long "logFile"
      <> metavar "PATH"
      <> help "Path for worker log file")
  return Worker{..}

-- | Returns the @(command, [arguments])@ to run the worker process
hyperionWorkerCommand :: FilePath -> Service -> FilePath -> (String, [String])
hyperionWorkerCommand hyperionExecutable service logFile =
  (hyperionExecutable, map T.unpack args)
  where
    args = [ "worker"
           , "--service", encodeService service
           , "--logFile", T.pack logFile
           ]
