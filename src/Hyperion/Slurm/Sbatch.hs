{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TypeApplications  #-}

module Hyperion.Slurm.Sbatch where

import           Control.Monad.Catch  (Exception, try)
import           Data.Attoparsec.Text (Parser, parseOnly, takeWhile1)
import           Data.Char            (isSpace)
import           Data.Text            (Text)
import qualified Data.Text            as T
import           Data.Time.Clock      (NominalDiffTime)
import qualified Hyperion.Log         as Log
import           Hyperion.Slurm.JobId (JobId (..))
import           Hyperion.Util        (retryRepeated)
import           Hyperion.Util        (hour)
import           System.Directory     (createDirectoryIfMissing)
import           System.Exit          (ExitCode (..))
import           System.Process       (readCreateProcessWithExitCode, shell)

data SbatchError = SbatchError (ExitCode, String, String)
  deriving (Show, Exception)

data SbatchOptions = SbatchOptions
  { jobName       :: Maybe Text
  , chdir         :: Maybe FilePath
  , output        :: Maybe FilePath
  , nodes         :: Int
  , nTasksPerNode :: Int
  , time          :: NominalDiffTime
  , mem           :: Maybe Text
  , mailType      :: Maybe Text
  , mailUser      :: Maybe Text
  , partition     :: Maybe Text
  } deriving (Show)

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

sbatchScript :: SbatchOptions -> String -> IO JobId
sbatchScript opts script = do
  maybe (return ()) (createDirectoryIfMissing True) (chdir opts)
  result@(exit, out, _) <- readCreateProcessWithExitCode (shell pipeToSbatch) ""
  case (exit, parseOnly sbatchOutputParser (T.pack out)) of
    (ExitSuccess, Right j) -> return j
    _                      -> Log.throw (SbatchError result)
  where
    pipeToSbatch = "printf '" ++ wrappedScript ++ "' | sbatch " ++ sBatchOptionString opts
    wrappedScript = "#!/bin/sh\n " ++ script

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

sbatchCommand :: SbatchOptions -> FilePath -> [Text] -> IO JobId
sbatchCommand opts cmd args = do
  retryRepeated 3 (try @IO @SbatchError) (sbatchScript opts script)
  where
    script = cmd ++ " " ++ unwords (map quote args)
    quote a = "\"" ++ T.unpack a ++ "\""
