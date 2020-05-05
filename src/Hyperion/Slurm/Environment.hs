{-# LANGUAGE TypeApplications #-}

module Hyperion.Slurm.Environment where

import           Control.Applicative       ((<|>))
import           Control.Monad.Trans.Maybe (MaybeT (..), runMaybeT)
import           Data.Maybe                (fromMaybe)
import           System.Environment        (lookupEnv)
import           System.Process            (readCreateProcess, shell)
import           Text.Read                 (readMaybe)

-- | Returns number of tasks per node by reading system environment variables.
-- If @SLURM_NTASKS_PER_NODE@ is defined, returns it. Otherwise, tries to compute
-- from @SLURM_NTASKS@ and @SLURM_JOB_NUM_NODES@. If this doens't work either,
-- fails with 'error'.
getNTasksPerNode :: IO Int
getNTasksPerNode =
  fromMaybe (error "Could not determine NTASKS_PER_NODE") <$>
  runMaybeT (lookupNTasks <|> computeNTasks)
  where
    lookupInt :: String -> MaybeT IO Int
    lookupInt name = MaybeT $ do
      mStr <- lookupEnv name
      return $ mStr >>= readMaybe @Int
    lookupNTasks = lookupInt "SLURM_NTASKS_PER_NODE"
    computeNTasks = do
      nTasks <- lookupInt "SLURM_NTASKS"
      nNodes <- lookupInt "SLURM_JOB_NUM_NODES"
      return (nTasks `div` nNodes)

-- | Returns the contents of @SLURM_JOB_NODELIST@ as a list of nodes names
getJobNodes :: IO [String]
getJobNodes = fmap lines $
  readCreateProcess (shell "scontrol show hostnames $SLURM_JOB_NODELIST") ""

-- | Returns the value of @SLURMD_NODENAME@
lookupHeadNode :: IO (Maybe String)
lookupHeadNode = lookupEnv "SLURMD_NODENAME"
