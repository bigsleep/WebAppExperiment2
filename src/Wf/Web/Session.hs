{-# LANGUAGE OverloadedStrings, DeriveDataTypeable, TypeFamilies, TemplateHaskell, StandaloneDeriving #-}
module Wf.Web.Session
( SessionState(..)
, SessionData(..)
, SessionKvs(..)
, SessionError(..)
, defaultSessionState
, defaultSessionData
) where

import qualified Control.Exception (Exception(..))
import qualified Wf.Control.Eff.Kvs as Kvs (KeyType)

import Data.Typeable (Typeable)
import qualified Data.HashMap.Strict as HM (HashMap, empty)
import qualified Data.ByteString as B (ByteString)
import Wf.Data.Serializable (Serializable(..))
import qualified Data.Aeson as DA (encode, decode)
import qualified Data.Aeson.TH as DA (deriveJSON, defaultOptions)

import qualified Wf.Application.Time as T (Time, mjd)

data SessionState = SessionState
    { sessionId :: B.ByteString
    , sessionData :: SessionData
    , isNew :: Bool
    } deriving (Show, Typeable)

data SessionData = SessionData
    { sessionValue :: HM.HashMap B.ByteString B.ByteString
    , sessionStartDate :: T.Time
    , sessionExpireDate :: T.Time
    } deriving (Show, Typeable)

DA.deriveJSON DA.defaultOptions ''SessionData
DA.deriveJSON DA.defaultOptions ''SessionState

defaultSessionState :: SessionState
defaultSessionState = SessionState "" defaultSessionData False

defaultSessionData :: SessionData
defaultSessionData = SessionData HM.empty T.mjd T.mjd

data SessionKvs = SessionKvs deriving (Typeable)

type instance Kvs.KeyType SessionKvs = B.ByteString

data SessionError =
    SessionError String
    deriving (Show, Eq, Typeable)

instance Control.Exception.Exception SessionError

instance Serializable SessionData where
    serialize = DA.encode
    deserialize = DA.decode