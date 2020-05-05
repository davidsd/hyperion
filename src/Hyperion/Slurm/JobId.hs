{-# LANGUAGE DuplicateRecordFields #-}

module Hyperion.Slurm.JobId where

import           Data.Text       (Text)

-- | Type for job id. A job can be idetified by id or by name, hence the two 
-- construtors.
data JobId
  = JobById Text
  | JobByName Text
  deriving (Show, Eq, Ord)
