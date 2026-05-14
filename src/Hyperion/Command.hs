{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Hyperion.Command where

import Hyperion.OsPath     (OsPath, takeDirectory)
import Hyperion.OsString   (OsString, fromString, toString)
import Hyperion.Util       (shellEsc)
import Hyperion.Worker     (Service (..), decodeService, encodeService)
import Options.Applicative (Parser, ReadM, eitherReader, help, long, metavar,
                            option, strOption)

-- Note: The argument list in hyperionWorkerCommand and the workerOpts
-- parser must be kept in sync.

-- | Haskell representation of arguments passed to the worker process.
data Worker = Worker
  { workerService :: Service
  , workerLogFile :: OsPath
  } deriving Show

serviceReader :: ReadM Service
serviceReader = eitherReader (decodeService . fromString)

serviceArg :: OsString
serviceArg = "service"

logFileArg :: OsString
logFileArg = "logFile"

-- | Parses worker command-line arguments. Essentially inverse to 'hyperionWorkerCommand'.
workerOpts :: Parser Worker
workerOpts = do
  workerService <- option serviceReader
    (long (toString serviceArg)
      <> metavar "SERVICE"
      <> help "Service on master process (binary encoded)")
  workerLogFile <- strOption
    (long (toString logFileArg)
      <> metavar "PATH"
      <> help "Path for worker log file")
  return Worker{..}

-- | Returns the @(command, [arguments])@ to run the worker process
-- NB: if it is called directly from the same executable on the same machine,
-- then MaxRSS for the worker will be wrong (inherited from parent).
-- See https://github.com/davidsd/hyperion/issues/3
hyperionWorkerCommand :: OsPath -> Service -> OsPath -> (OsString, [OsString])
hyperionWorkerCommand hyperionExecutable service logFile =
  ( hyperionExecutable
  , [ "worker"
    , "--"<>serviceArg, encodeService service
    , "--"<>logFileArg, logFile
    ]
  )

-- | sh -c hyperionWorkerCommand
-- Returns the @(command, [arguments])@ to run the worker process in a new shell process.
-- This is a workaround for MaxRSS issue, see comment for hyperionWorkerCommand
shHyperionWorkerCommand :: OsPath -> Service -> OsPath -> (OsString, [OsString])
shHyperionWorkerCommand hyperionExecutable service logFile =
  ( "sh"
  , [ "-c"
    , uncurry shellEsc $ hyperionWorkerCommand hyperionExecutable service logFile
    ])
