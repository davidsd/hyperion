{-# LANGUAGE ApplicativeDo       #-}
{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE TypeApplications    #-}

module Hyperion.Slurm.Sbatch where

import Control.Applicative     (optional)
import Control.Monad.Catch     (Exception)
import Data.Attoparsec.Text    (char, decimal, endOfInput, parseOnly, sepBy1,
                                takeWhile1)
import Data.Attoparsec.Text    qualified as Attoparsec
import Data.Char               (isSpace)
import Data.List               (intersperse)
import Data.Maybe              (catMaybes)
import Data.Text               qualified as T
import Data.Time.Clock         (NominalDiffTime)
import Hyperion.Log            qualified as Log
import Hyperion.OsPath         (OsPath, takeDirectory)
import Hyperion.OsString       (OsString, fromString, showOs, toString)
import Hyperion.Slurm.JobId    (JobId (..))
import Hyperion.Util           (day, hour, minute)
import Options.Applicative     (ReadM, auto, eitherReader, long, metavar,
                                option, short, switch, value)
import Options.Applicative     qualified as Applicative
import System.Directory.OsPath (createDirectoryIfMissing)
import System.Exit             (ExitCode (..))
import System.Process          (readCreateProcessWithExitCode, shell)

-- | Error from running @sbatch@. The 'String's are the contents of 'stdout'
-- and 'stderr' from @sbatch@.
data SbatchError = SbatchError
  { exitCodeStdinStderr :: (ExitCode, OsString, OsString)
  , input               :: OsString
  } deriving (Show, Exception)

-- | Type representing possible options for @sbatch@. Map 1-to-1 to @sbatch@
-- options, so see @man sbatch@ for details.
data SbatchOptions = SbatchOptions
  {
  -- | Job name (\"--job-name\")
    jobName        :: Maybe OsString
  -- | Working directory for the job (\"--D\")
  , chdir          :: Maybe OsPath
  -- | Where to direct 'stdout' of the job (\"--output\")
  , output         :: Maybe OsPath
  -- | Number of nodes (\"--nodes\")
  , nodes          :: Int
  -- | Number of tasks per node (\"--ntasks-per-node\")
  , nTasksPerNode  :: Int
  -- | Job time limit (\"--time\")
  , time           :: NominalDiffTime
  -- | Memory per node, use suffix K,M,G, or T to define the units. (\"--mem\")
  , mem            :: Maybe OsString
  -- | (\"--mail-type\")
  , mailType       :: Maybe OsString
  -- | (\"--mail-user\")
  , mailUser       :: Maybe OsString
  -- | @SLURM@ partition (\"--partition\")
  , partition      :: Maybe OsString
  -- | (\"--constraint")
  , constraint     :: Maybe OsString
  -- | (\"--account")
  , account        :: Maybe OsString
  -- | (\"--qos")
  , qos            :: Maybe OsString
  -- | (\"--no-requeue")
  , noRequeue      :: Bool
  -- | code to inject in sbatch script before the commands
  , scriptPreamble :: Maybe OsString
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
  , constraint      = Nothing
  , account         = Nothing
  , qos             = Nothing
  , noRequeue       = True
  , scriptPreamble   = Nothing
  }

-- | Convert 'SbatchOptions' to a string of options for @sbatch@
sBatchOptionString :: SbatchOptions -> OsString
sBatchOptionString opts =
  unwords' [ opt <> " " <> val | (opt, Just val) <- optPairs]
  where
    unwords' = mconcat . intersperse " "
    optPairs =
      [ ("--job-name",        opts.jobName)
      -- sbatch changed this option from workdir to chdir
      -- at some point, so we need to use the short name
      , ("-D",                opts.chdir)
      , ("--output",          opts.output)
      , ("--nodes",           Just (showOs opts.nodes))
      , ("--ntasks-per-node", Just (showOs opts.nTasksPerNode))
      , ("--time",            Just (formatRuntime opts.time))
      , ("--mem",             opts.mem)
      , ("--mail-type",       opts.mailType)
      , ("--mail-user",       opts.mailUser)
      , ("--partition",       opts.partition)
      , ("--constraint",      opts.constraint)
      , ("--account",         opts.account)
      , ("--qos",             opts.qos)
      , ("--no-requeue",      if opts.noRequeue then Just "" else Nothing)
      ]

-- | Parse command-line options for sbatch, see https://slurm.schedmd.com/sbatch.html#SECTION_OPTIONS
sBatchOptionsParser :: Applicative.Parser SbatchOptions
sBatchOptionsParser = do
  jobName <- optional $ option auto $ short 'J' <> long "job-name" <> metavar "STRING"
  chdir <- optional $ option auto $ short 'D' <> long "chdir" <> metavar "STRING"
  output <- optional $ option auto $ short 'o' <> long "output" <> metavar "STRING"
  nodes <- option auto $ short 'N' <> long "nodes" <> value defaultSbatchOptions.nodes <> metavar "INT"
  nTasksPerNode <-option auto $ long "ntasks-per-node" <> value defaultSbatchOptions.nTasksPerNode <> metavar "INT"
  time <- option readTime $ short 't' <> long "time" <> value defaultSbatchOptions.time <> metavar "INT"
  mem <- optional $ option auto $ long "mem" <> metavar "STRING"
  mailType <- optional $ option auto $ long "mail-type" <> metavar "STRING"
  mailUser <- optional $ option auto $ long "mail-user" <> metavar "STRING"
  partition <- optional $ option auto $ short 'p' <> long "partition" <> metavar "STRING"
  constraint <- optional $ option auto $ short 'C' <> long "constraint" <> metavar "STRING"
  account <- optional $ option auto $ short 'A' <> long "account" <> metavar "STRING"
  qos <- optional $ option auto $ short 'q' <> long "qos" <> metavar "STRING"
  noRequeue <- switch $ long "no-requeue"
  scriptPreamble <- optional $ option auto $ long "script-preamble" <> metavar "STRING"
  pure SbatchOptions {..}
  where
    readTime :: ReadM NominalDiffTime
    readTime = eitherReader $ parseOnly (slurmTimeParser <* endOfInput) . T.pack

    slurmTimeParser :: Attoparsec.Parser NominalDiffTime
    slurmTimeParser = do
      dd :: Maybe Integer <- optional $ decimal <* char '-'
      hmsList :: [Integer] <- decimal `sepBy1` char ':'
      dhms <- case (dd, hmsList) of
        (Nothing, [m])       -> pure [0, 0, m, 0]
        (Nothing, [m, s])    -> pure [0, 0, m, s]
        (Nothing, [h, m, s]) -> pure [0, h, m, s]
        (Just d, [h])        -> pure [d, h, 0, 0]
        (Just d, [h, m])     -> pure [d, h, m, 0]
        (Just d, [h, m, s])  -> pure [d, h, m, s]
        _                    -> fail "invalid SLURM time format"
      pure $ sum $
        zipWith (*)
        (fromIntegral <$> dhms)
        [day, hour, minute, 1]

sbatchOutputParser :: Attoparsec.Parser JobId
sbatchOutputParser = JobId <$> ("Submitted batch job " *> takeWhile1 (not . isSpace) <* "\n")

-- | Runs @sbatch@ on a batch file with options pulled from 'SbatchOptions' and
-- script given as the 'OsPath' input parameter. If 'sbatch' exists with failure
-- then throws 'SbatchError'.
sbatchScript :: SbatchOptions -> OsPath -> IO JobId
sbatchScript opts script = do
  mapM_ (createDirectoryIfMissing True) $
    catMaybes [ chdir opts
              , fmap takeDirectory opts.output
              ]
  (exit, out, err) <- readCreateProcessWithExitCode (shell $ toString pipeToSbatch) ""
  case (exit, parseOnly sbatchOutputParser (T.pack out)) of
    (ExitSuccess, Right j) -> return j
    _                      -> Log.throw (SbatchError (exit, fromString out, fromString err) pipeToSbatch)
  where
    pipeToSbatch = "printf '" <> wrappedScript <> "' | sbatch " <> sBatchOptionString opts
    preamble = case opts.scriptPreamble of
      Just t  -> t <> "\n"
      Nothing -> ""
    wrappedScript = "#!/bin/sh\n" <> preamble <> script

-- | Formats 'NominalDiffTime' into @hh:mm:ss@.
formatRuntime :: NominalDiffTime -> OsString
formatRuntime t = padNum h <> ":" <> padNum m <> ":" <> padNum s
  where
    h = quotBy 3600 t
    m = remBy 60 (quotBy 60 t)
    s = remBy 60 (quotBy 1 t)

    padNum x = fromString $ case length (show x) of
      1 -> '0' : show x
      _ -> show x

    quotBy :: Real t => t -> t -> Integer
    quotBy d n = truncate (toRational n / toRational d)

    remBy :: Real t => t -> t -> t
    remBy d n = n - (fromInteger f) * d where
      f = quotBy d n

-- | Runs the command given by 'OsPath' with arguments @['OsString']@ in
-- @sbatch@ script via 'sbatchScript'. If 'sbatch' fails then throws
-- 'SbatchError'.
sbatchCommand :: SbatchOptions -> OsPath -> [OsString] -> IO JobId
sbatchCommand opts cmd args = sbatchScript opts script
  where
    script = cmd <> " " <> unwords' (map quote args)
    quote a = "\"" <> a <> "\""
    unwords' = mconcat . intersperse " "
