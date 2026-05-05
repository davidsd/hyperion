-- Extension module for System.OsPath, providing Binary, ToText, ToJSON etc. instances from Hyperion.OsString (= OsPath).
-- NB: Only POSIX paths are supported now

module Hyperion.OsPath
  ( module System.OsPath
  ) where

import Hyperion.OsString ()
import System.OsPath
