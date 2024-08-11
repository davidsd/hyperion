module Hyperion.Slurm.JobId where

import Data.Text (Text)

-- | Type for job id. A job can be idetified by id or by name, hence the two
-- construtors.
data JobId = JobId Text | JobName Text
  deriving (Show, Eq, Ord)
