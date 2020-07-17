{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TypeApplications  #-}

module Hyperion.Slurm.Sbatch where

import           Control.Monad.Catch   (Exception, try)
import           Data.Attoparsec.Text  (Parser, parseOnly, takeWhile1)
import           Data.Char             (isSpace)
import           Data.Maybe            (catMaybes)
import           Data.Text             (Text)
import qualified Data.Text             as T
import           Data.Time.Clock       (NominalDiffTime)
import qualified Hyperion.Log          as Log
import           Hyperion.Slurm.JobId  (JobId (..))
import           Hyperion.Util         (hour, retryRepeated)
import           System.Directory      (createDirectoryIfMissing)
import           System.Exit           (ExitCode (..))
import           System.FilePath.Posix (takeDirectory)
import           System.Process        (readCreateProcessWithExitCode, shell)

-- | Error from running @sbatch@. The 'String's are the contents of 'stdout'
-- and 'stderr' from @sbatch@.
data SbatchError = SbatchError
  { exitCodeStdinStderr :: (ExitCode, String, String)
  , input :: String
  } deriving (Show, Exception)

-- | Type representing possible options for @sbatch@. Map 1-to-1 to @sbatch@
-- options, so see @man sbatch@ for details.
data SbatchOptions = SbatchOptions
  {
  -- | Job name (\"--job-name\")
    jobName       :: Maybe Text
  -- | Working directory for the job (\"--D\")
  , chdir         :: Maybe FilePath
  -- | Where to direct 'stdout' of the job (\"--output\")
  , output        :: Maybe FilePath
  -- | Number of nodes (\"--nodes\")
  , nodes         :: Int
  -- | Number of tasks per node (\"--ntasks-per-node\")
  , nTasksPerNode :: Int
  -- | Job time limit (\"--time\")
  , time          :: NominalDiffTime
  -- | Memory per node, use suffix K,M,G, or T to define the units. (\"--mem\")
  , mem           :: Maybe Text
  -- | (\"--mail-type\")
  , mailType      :: Maybe Text
  -- | (\"--mail-user\")
  , mailUser      :: Maybe Text
  -- | @SLURM@ partition (\"--partition\")
  , partition     :: Maybe Text
  } deriving (Show)

-- | Default 'SbatchOptions'. Request 1 task on 1 node for 24 hrs, everything else
-- unspecified.
defaultSbatchOptions :: SbatchOptions
defaultSbatchOptions = SbatchOptions
  { jobName         = Nothing
  , chdir           = Nothing
  , output          = Nothing
  , nodes           = 1
  , nTasksPerNode   = 1
  , time            = 24*hour
  , mem             = Nothing
  , mailType        = Nothing
  , mailUser        = Nothing
  , partition       = Nothing
  }

-- Convert 'SbatchOptions' to a string of options for @sbatch@
sBatchOptionString :: SbatchOptions -> String
sBatchOptionString SbatchOptions{..} =
  unwords [ opt ++ " " ++ val | (opt, Just val) <- optPairs]
  where
    optPairs =
      [ ("--job-name",        fmap T.unpack jobName)
      -- sbatch changed this option from workdir to chdir
      -- at some point, so we need to use the short name
      , ("-D",                chdir)
      , ("--output",          output)
      , ("--nodes",           Just (show nodes))
      , ("--ntasks-per-node", Just (show nTasksPerNode))
      , ("--time",            Just (formatRuntime time))
      , ("--mem",             fmap T.unpack mem)
      , ("--mail-type",       fmap T.unpack mailType)
      , ("--mail-user",       fmap T.unpack mailUser)
      , ("--partition",       fmap T.unpack partition)
      ]

sbatchOutputParser :: Parser JobId
sbatchOutputParser = JobById <$> ("Submitted batch job " *> takeWhile1 (not . isSpace) <* "\n")

-- | Runs @sbatch@ on a batch file with options pulled from 'SbatchOptions' and
-- script given as the 'String' input parameter. If 'sbatch' exists with failure
-- then throws 'SbatchError'.
sbatchScript :: SbatchOptions -> String -> IO JobId
sbatchScript opts script = do
  mapM_ (createDirectoryIfMissing True) $
    catMaybes [ chdir opts
              , fmap takeDirectory (output opts)
              ]
  result@(exit, out, _) <- readCreateProcessWithExitCode (shell pipeToSbatch) ""
  case (exit, parseOnly sbatchOutputParser (T.pack out)) of
    (ExitSuccess, Right j) -> return j
    _                      -> Log.throw (SbatchError result pipeToSbatch)
  where
    pipeToSbatch = "printf '" ++ wrappedScript ++ "' | sbatch " ++ sBatchOptionString opts
    wrappedScript = "#!/bin/sh\n " ++ script

-- | Formats 'NominalDiffTime' into @hh:mm:ss@.
formatRuntime :: NominalDiffTime -> String
formatRuntime t = padNum h ++ ":" ++ padNum m ++ ":" ++ padNum s
  where
    h = quotBy 3600 t
    m = remBy 60 (quotBy 60 t)
    s = remBy 60 (quotBy 1 t)

    padNum x = case length (show x) of
      1 -> '0' : show x
      _ -> show x

    quotBy :: Real t => t -> t -> Integer
    quotBy d n = truncate (toRational n / toRational d)

    remBy :: Real t => t -> t -> t
    remBy d n = n - (fromInteger f) * d where
      f = quotBy d n

-- | Runs the command given by 'FilePath' with arguments @['Text']@
-- in @sbatch@ script via 'sbatchScript'. If 'sbatchScript' throws
-- 'SbatchError', retries for a total of 3 attempts (via 'retryRepeated').
sbatchCommand :: SbatchOptions -> FilePath -> [Text] -> IO JobId
sbatchCommand opts cmd args =
  retryRepeated 3 (try @IO @SbatchError) (sbatchScript opts script)
  where
    script = cmd ++ " " ++ unwords (map quote args)
    quote a = "\"" ++ T.unpack a ++ "\""
