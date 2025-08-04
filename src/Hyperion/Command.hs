{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Hyperion.Command where

import Data.Text             qualified as Text
import Hyperion.Util         (shellEsc)
import Hyperion.Worker       (Service (..), decodeService, encodeService)
import Options.Applicative   (Parser, ReadM, eitherReader, help, long, metavar,
                              option, strOption)
import System.FilePath.Posix (takeDirectory)

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
-- NB: if it is called directly from the same executable on the same machine,
-- then MaxRSS for the worker will be wrong (inherited from parent).
-- See https://github.com/davidsd/hyperion/issues/3
hyperionWorkerCommand :: FilePath -> Service -> FilePath -> (String, [String])
hyperionWorkerCommand hyperionExecutable service logFile =
  ( hyperionExecutable
  , [ "worker"
    , "--"<>serviceArg, Text.unpack $ encodeService service
    , "--"<>logFileArg, logFile
    ]
  )

-- | /usr/bin/time -v hyperionWorkerCommand
-- Returns the @(command, [arguments])@ to run the worker process prepended by "/usr/bin/time -v".
-- NB: since we redirect /usr/bin/time output to logFile, we have to create directory first.
timeHyperionWorkerCommand :: FilePath -> Service -> FilePath -> (String, [String])
timeHyperionWorkerCommand hyperionExecutable service logFile =
  ( "sh"
  , [ "-c"
    , shellEsc "mkdir" ["-p", takeDirectory logFile]
      ++ " && "
      ++ shellEsc "/usr/bin/time"
        [ "-v"
        , hyperionExecutable
        , "worker"
        , "--" <> serviceArg, Text.unpack $ encodeService service
        , "--" <> logFileArg, logFile
        ]
        ++ " >>" ++ logFile ++ " 2>&1"
    ]
  )
