{-# LANGUAGE OverloadedStrings, TypeOperators, FlexibleContexts, TemplateHaskell, TypeFamilies #-}
module Main where

import Control.Eff (Member, Eff, (:>))
import Control.Eff.State.Strict (State, evalState)
import Control.Eff.Reader.Strict (Reader, ask, runReader)
import Control.Eff.Exception (runExc)
import Control.Eff.Lift (Lift, runLift, lift)
import Control.Monad (mzero, unless)
import Control.Exception (SomeException(..))

import qualified Data.List as List (lookup)
import Data.Either (either)
import Data.Typeable (cast)
import qualified Data.ByteString as B (ByteString, append)
import qualified Data.ByteString.Char8 as B (pack)
import qualified Data.ByteString.Lazy as L (ByteString, readFile, length, empty)
import qualified Data.Aeson as DA (Value(..), FromJSON(..), decode, encode, (.:))
import qualified Data.Aeson.TH as DA (deriveJSON, defaultOptions)
import qualified Database.Redis as Redis (ConnectInfo)

import qualified Network.Wai as Wai (Request, Response, defaultRequest, requestHeaders, responseLBS, responseStatus, responseHeaders)
import qualified Network.HTTP.Client as N (Request(..), RequestBody(..), Response(..), Manager, parseUrl, newManager, defaultManagerSettings)
import qualified Network.HTTP.Client.TLS as N (tlsManagerSettings)
import qualified Network.HTTP.Types as HTTP (Method, hContentType, hContentLength, status500)
import qualified Network.Wai.Handler.Warp as Warp (run)

import Wf.Control.Eff.Kvs (Kvs)
import Wf.Control.Eff.HttpClient (HttpClient, httpClient, runHttpClient)
import Wf.Control.Eff.Authenticate (Authenticate, AuthenticationType(..), authenticate, authenticationTransfer)
import Wf.Control.Eff.Run.Authenticate.OAuth2 (runAuthenticateOAuth2)
import Wf.Control.Eff.Run.Kvs.Redis (runKvsRedis)
import Wf.Web.Authenticate.OAuth2 (OAuth2(..), OAuth2Error(..))
import Wf.Network.Http.Types (Request, Response, defaultResponse, requestMethod, requestRawPath, requestHeaders, requestQuery)
import Wf.Network.Http.Response (setStatus, addHeader, setHeaders, redirect, setBody)
import Wf.Network.Wai (toWaiApplication)
import Wf.Web.Session (Session, sget, sput, sdestroy, renderSetCookie, runSession, SessionState, defaultSessionState, SessionKvs, SessionSettings(sessionName), getRequestSessionId)
import Wf.Web.Api (apiRoutes, getApi)
import Wf.Application.Time (Time, getCurrentTime)
import Wf.Application.Exception (Exception, throwException)
import Wf.Application.Logger (Logger, logDebug, runLoggerStdIO, LogLevel(..))

import Settings (Settings(..))

data User = User
    { userId :: B.ByteString
    , userName :: B.ByteString
    , userEmail :: B.ByteString
    } deriving (Show, Eq)

DA.deriveJSON DA.defaultOptions ''User

newtype GoogleUser = GoogleUser { unGoogleUser :: User } deriving (Show, Eq)

instance DA.FromJSON GoogleUser where
    parseJSON (DA.Object o) = do
        uid <- o DA..: "id"
        uname <- o DA..: "displayName"
        uemail' <- fmap head (o DA..: "emails")
        uemail <- uemail' DA..: "value"
        return $ GoogleUser User { userId = uid, userName = uname, userEmail = uemail }
    parseJSON _ = mzero

main :: IO ()
main = do
    settings <- loadSettings
    manager <- N.newManager N.tlsManagerSettings

    let oauth2 = OAuth2 { oauth2Config = settingsOAuth2 settings, oauth2UserParser = fmap unGoogleUser . DA.decode }
        port = settingsPort settings
        redis = settingsRedis settings
        sessionSettings = settingsSession settings
        server = toWaiApplication $ run oauth2 redis manager sessionSettings routes

    Warp.run port server

    where
    loadSettings :: IO Settings
    loadSettings = do
        a <- fmap DA.decode . L.readFile $ "oauth2-example/config/settings.json"
        case a of
             Just settings -> return settings
             Nothing -> error "load failure"


type M = Eff
    (  Authenticate ()
    :> HttpClient
    :> Session
    :> Kvs SessionKvs
    :> State SessionState
    :> Logger
    :> Exception
    :> Lift IO
    :> ())

routes :: Request L.ByteString -> M (Response L.ByteString)
routes request = apiRoutes rootApp rs request method path
    where
    rs = [ getApi "/" (const rootApp)
         , getApi "/login" (const loginApp)
         , getApi "/oauth2callback" oauth2CallbackApp
         ]
    method = requestMethod request
    path = requestRawPath request

instance AuthenticationType () where
    type AuthenticationKeyType () = (B.ByteString, B.ByteString)
    type AuthenticationUserType () = User

rootApp :: M (Response L.ByteString)
rootApp = do
    maybeUser <- sget "login_user" :: M (Maybe User)

    case maybeUser of
         Just user -> let body = DA.encode user
                          contentType = (HTTP.hContentType, "application/json")
                          contentLength = (HTTP.hContentLength, B.pack . show . L.length $ body)
                          headers = [contentType, contentLength]
                      in return . setHeaders headers $ defaultResponse body
         Nothing -> return . redirect "http://localhost:3000/login" $ (defaultResponse "")

loginApp :: M (Response L.ByteString)
loginApp = fmap (setBody "") $ authenticationTransfer () (defaultResponse ())

oauth2CallbackApp :: Request L.ByteString -> M (Response L.ByteString)
oauth2CallbackApp req = do
    let maybeCode = id =<< (List.lookup "code" . requestQuery $ req)
    maybeState <- sget "state"

    logDebug $ "state code " ++ show (maybeState, maybeCode)
    user <- case (maybeState, maybeCode) of
                 (Just state, Just code) -> authenticate () (code, state)
                 _ -> throwException $ redirect "http://localhost:3000/login" $ (defaultResponse L.empty)

    logDebug $ "loginUser: " ++ show user

    sdestroy
    sput "login_user" user
    setCookie <- renderSetCookie
    return . redirect "http://localhost:3000/" . addHeader setCookie $ (defaultResponse "")


run :: OAuth2 User
    -> Redis.ConnectInfo
    -> N.Manager
    -> SessionSettings
    -> (Request L.ByteString -> M (Response L.ByteString))
    -> Request L.ByteString
    -> IO (Response L.ByteString)
run oauth2 redis manager sessionSettings app request = do
    t <- getCurrentTime
    run' t request

    where
    run' t =
          runLift
        . (>>= handleError)
        . runExc
        . runLoggerStdIO DEBUG
        . evalState defaultSessionState
        . runKvsRedis redis
        . runSession sessionSettings t requestSessionId
        . runHttpClient manager
        . runAuthenticateOAuth2 oauth2
        . app
    internalError = setStatus HTTP.status500 $ defaultResponse "<p>InternalError<p>"
    sname = sessionName sessionSettings
    requestSessionId = getRequestSessionId sname . requestHeaders $ request
    handleError (Left (SomeException e)) = do
        lift $ print e
        case cast e of
             Just r -> return r
             _ -> return internalError
    handleError (Right r) = return r
