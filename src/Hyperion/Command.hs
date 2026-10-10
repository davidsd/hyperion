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

-- Note: 'workerArgs' and the 'workerOpts' parser must agree; test/Main.hs
-- checks that the arguments of a 'Worker' parse back into the same 'Worker'.

-- | Haskell representation of arguments passed to the worker process.
data Worker = Worker
  { workerService :: Service
  , workerLogFile :: OsPath
  } deriving (Eq, Show)

serviceReader :: ReadM Service
serviceReader = eitherReader (decodeService . fromString)

serviceArg :: OsString
serviceArg = "service"

logFileArg :: OsString
logFileArg = "logFile"

-- | Parses worker command-line arguments. Inverse to 'workerArgs'.
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

-- | The arguments that make the hyperion executable run as the given
-- worker: the @worker@ command followed by what 'workerOpts' parses.
workerArgs :: Worker -> [OsString]
workerArgs worker =
  [ "worker"
  , "--"<>serviceArg, encodeService (workerService worker)
  , "--"<>logFileArg, workerLogFile worker
  ]

-- | The given command, run by a new @sh@ process. A worker started this
-- way by a hyperion process on the same machine gets its own maximum
-- resident set size, instead of inheriting the parent's: see
-- https://github.com/davidsd/hyperion/issues/3
inNewShell :: (OsString, [OsString]) -> (OsString, [OsString])
inNewShell (command, args) = ("sh", ["-c", shellEsc command args])
