{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StaticPointers    #-}

-- Extension module for System.OsString, providing Binary, ToText, ToJSON etc. instances
-- NB: Only POSIX strings are supported now

module Hyperion.OsString
  ( module Hyperion.OsString
  , module System.OsString
  , toText
  , fromString
  ) where

import Data.Aeson                     (FromJSON (..), ToJSON (..))
import Data.Attoparsec.ByteString     (parseOnly)
import Data.Binary                    (Binary (..))
import Data.BinaryHash                (hashUntypedBase64SafeByteString)
import Data.ByteString                qualified as B
import Data.ByteString.Builder        (byteString)
import Data.ByteString.Conversion     (FromByteString (..), ToByteString (..))
import Data.ByteString.Lazy           qualified as BL
import Data.ByteString.Short          qualified as BS
import Data.String                    (IsString (..))
import Data.Text                      (Text)
import Data.Text                      qualified as Text
import Data.Text.Conversions          (ToText (..))
import Hyperion.Static                (Dict (..), Static, closureDict)
import System.OsString
import System.OsString.Internal.Types (OsString (..), PosixString (..))
import Type.Reflection                (Typeable, typeOf)

instance Binary PosixString where
  put (PosixString bs) = put bs
  get = PosixString <$> get

-- | Serialize 'OsString' using its native in-memory platform representation.
--
-- The resulting encoding is platform-specific: POSIX paths are serialized as
-- raw bytes, while Windows paths are serialized as their native short
-- bytestring representation.
instance Binary OsString where
  put (OsString s) = put s
  get = OsString <$> get

instance Static (Binary OsString) where
  closureDict = static Dict

instance ToJSON OsString where
  toJSON = toJSON . unsafeDecodeUtf

instance FromJSON OsString where
  parseJSON v = unsafeEncodeUtf <$> parseJSON v

-- TODO: these conversions to/from Text go through String, will they be optimized?
instance ToText OsString where
  toText = toText . unsafeDecodeUtf

fromText :: Text -> OsString
fromText = unsafeEncodeUtf . Text.unpack

instance IsString OsString where
  fromString = unsafeEncodeUtf

toString :: OsString -> String
toString = unsafeDecodeUtf

showOs :: (Show a) => a -> OsString
showOs = fromString . show

instance ToByteString BS.ShortByteString where
  builder = byteString . BS.fromShort
instance ToByteString PosixString where
  builder (PosixString sbs) = builder sbs
instance ToByteString OsString where
  builder (OsString s) = builder s

instance FromByteString BS.ShortByteString where
  parser = BS.toShort . BL.toStrict <$> parser
instance FromByteString PosixString where
  parser = PosixString <$> parser
instance FromByteString OsString where
  parser = OsString <$> parser

unsafeDecodeUtf :: OsString -> String
unsafeDecodeUtf os = case decodeUtf os of
  Left err -> error $ "decodeUtf error: " ++ show (os, err)
  Right s  -> s

unsafeFromByteString :: FromByteString a => B.ByteString -> a
unsafeFromByteString = either error id . parseOnly parser

hashBase64SafeOsString :: (Binary a, Typeable a) => a -> OsString
hashBase64SafeOsString = hashUntypedBase64SafeOsString . withType where
  withType x = (x, typeOf x)

-- | URL-encoded hash as a OsString
hashUntypedBase64SafeOsString :: Binary a => a -> OsString
hashUntypedBase64SafeOsString = unsafeFromByteString . hashUntypedBase64SafeByteString

