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

import Wf.Control.Eff.HttpClient (HttpClient, httpClient, runHttpClient)
import Wf.Control.Eff.Authenticate (Authenticate, AuthenticationType(..), authenticate, authenticationTransfer)
import Wf.Control.Eff.Run.Authenticate.OAuth2 (runAuthenticateOAuth2)
import Wf.Web.Authenticate.OAuth2 (OAuth2(..), OAuth2Error(..))
import Wf.Network.Http.Types (Request, Response, defaultResponse, requestMethod, requestRawPath, requestHeaders, requestQuery)
import Wf.Network.Http.Response (setStatus, addHeader, setHeaders, redirect, setBody, file, json)
import Wf.Network.Wai (toWaiResponse, toWaiApplication)
import Wf.Web.Session (Session, sget, sput, sdestroy, renderSetCookie, SessionState, defaultSessionState, SessionSettings(sessionName), getRequestSessionId)
import Wf.Control.Eff.Run.Session.Stm (SessionStore, initializeSessionStore, runSessionStm)
import Wf.Web.Api (apiRoutes, getApi, postApi)
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
    sessionStore <- initializeSessionStore (2 *60 * 1000000)

    let oauth2 = OAuth2 { oauth2Config = settingsOAuth2 settings, oauth2UserParser = fmap unGoogleUser . DA.decode }
        port = settingsPort settings
        uri = settingsUri settings
        sessionSettings = settingsSession settings
        server = toWaiApplication $ run oauth2 manager sessionStore sessionSettings (routes uri)

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
    :> State SessionState
    :> Logger
    :> Exception
    :> Lift IO
    :> ())

routes :: B.ByteString -> Request L.ByteString -> M Wai.Response
routes uri request = apiRoutes rootApp rs request method path
    where
    rs = [ getApi "/" (const rootApp)
         , postApi "/login" (const loginApp)
         , getApi "/oauth2callback" (oauth2CallbackApp uri)
         ]
    method = requestMethod request
    path = requestRawPath request

instance AuthenticationType () where
    type AuthenticationKeyType () = (B.ByteString, B.ByteString)
    type AuthenticationUserType () = User

rootApp :: M Wai.Response
rootApp = do
    maybeUser <- sget "login_user" :: M (Maybe User)

    case maybeUser of
         Just user -> return . toWaiResponse . json (DA.encode user) $ defaultResponse ()
         Nothing -> return . toWaiResponse . file "oauth2-example/static/index.html" $ defaultResponse ()

loginApp :: M Wai.Response
loginApp = fmap toWaiResponse $ authenticationTransfer () $ defaultResponse ()

oauth2CallbackApp :: B.ByteString -> Request L.ByteString -> M Wai.Response
oauth2CallbackApp uri req = do
    let maybeCode = id =<< (List.lookup "code" . requestQuery $ req)
    maybeState <- sget "state"

    logDebug $ "state code " ++ show (maybeState, maybeCode)
    user <- case (maybeState, maybeCode) of
                 (Just state, Just code) -> authenticate () (code, state)
                 _ -> throwException $ redirect (uri `B.append` "/login") $ defaultResponse ()

    logDebug $ "loginUser: " ++ show user

    sdestroy
    sput "login_user" user
    setCookie <- renderSetCookie
    return . toWaiResponse . redirect uri . addHeader setCookie $ defaultResponse ()


run :: OAuth2 User
    -> N.Manager
    -> SessionStore
    -> SessionSettings
    -> (Request L.ByteString -> M Wai.Response)
    -> Request L.ByteString
    -> IO Wai.Response
run oauth2 manager sessionStore sessionSettings app request = do
    t <- getCurrentTime
    run' t request

    where
    run' t =
          runLift
        . (>>= handleError)
        . runExc
        . runLoggerStdIO DEBUG
        . evalState defaultSessionState
        . runSessionStm sessionStore sessionSettings t requestSessionId
        . runHttpClient manager
        . runAuthenticateOAuth2 oauth2
        . app
    internalError = toWaiResponse . setStatus HTTP.status500 . file "oauth2-example/static/error.html" $ defaultResponse ()
    sname = sessionName sessionSettings
    requestSessionId = getRequestSessionId sname . requestHeaders $ request
    handleError (Left (SomeException e)) = do
        lift $ print e
        case cast e of
             Just r -> return r
             _ -> return internalError
    handleError (Right r) = return r
