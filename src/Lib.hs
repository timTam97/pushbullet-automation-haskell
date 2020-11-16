{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Lib where

-- import Data.List
-- import qualified Network.WebSockets.Client as WS

-- someFunc :: IO ()
-- someFunc = putStrLn "someFunc"
import Data.IORef ( newIORef, readIORef, writeIORef )
import Control.Monad (forever, when)
import Control.Monad.IO.Class ()
import Control.Monad.Trans (liftIO)
import Data.Aeson
    ( decode,
      defaultOptions,
      FromJSON(parseJSON),
      Options(fieldLabelModifier),
      Value )
-- import Data.Aeson (decode, defaultOptions)
import Data.Aeson.TH ( deriveJSON )
import Data.Aeson.Types ( parseMaybe )
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Text (Text, unpack)
import qualified Data.Text.IO as T
import Data.Time.Clock.POSIX ( getPOSIXTime )
import Network.HTTP.Req
    ( (/:),
      (=:),
      defaultHttpConfig,
      header,
      https,
      jsonResponse,
      req,
      responseBody,
      runReq,
      GET(GET),
      NoReqBody(NoReqBody) )
import qualified Network.WebSockets as WS
import System.IO (IOMode (ReadMode), hGetLine, openFile)
import qualified Wuss as WWS
import Data.Maybe ( fromJust, isJust )
import qualified Sys as SYS
import Debug.Trace ()
data RecData = RecData {mainType :: String, subtype :: Maybe String}
  deriving (Show)

newtype Push
  = Push {pushes :: [SubPushes]}
  deriving Show

data SubPushes = SubPushes {
  title :: String,
  body :: String,
  modified :: Double,
  dismissed :: Bool,
  sender_name :: String
} deriving (Show)

-- https://stackoverflow.com/questions/48474587/how-to-deal-with-haskells-reserved-keywords-in-record-fields
$( deriveJSON
     defaultOptions
       { fieldLabelModifier =
           \x -> if x == "mainType" then "type" else x
       }
     ''RecData
 )
$(deriveJSON defaultOptions ''Push)
$(deriveJSON defaultOptions ''SubPushes)

currentUnixTime :: IO Integer
currentUnixTime = do floor <$> getPOSIXTime

getToken :: IO String
getToken = do
  handle <- openFile "src\\token.txt" ReadMode
  hGetLine handle

fromJSONValue :: FromJSON a => Value -> Maybe a
fromJSONValue = parseMaybe parseJSON

processCommand :: String -> IO ()
processCommand c = 
  case c of
    "sleep" -> SYS.setSuspendState False
    "hibernate" -> SYS.setSuspendState True
    "shut down" -> undefined
    "lock" -> SYS.lockWorkStation

interrogateResponse :: Push -> Integer -> IO Integer
interrogateResponse p n =
  if title subPush == "LENOVO-TIM" 
    && body subPush /= ""
    && not (dismissed subPush)
  then do
    processCommand $ body subPush
    pure $ floor $ modified subPush
  else
    pure n
  where
    subPush = head $ pushes p

grabPush :: Integer -> IO (Maybe Push)
grabPush t = do
  token <- getToken
  runReq defaultHttpConfig $ do
    r <-
      req
        GET
        (https "api.pushbullet.com" /: "v2" /: "pushes")
        NoReqBody
        jsonResponse
        ( header "Access-Token" (BS.pack token)
            <> ("modified_after" =: (show t :: String))
            <> ("active" =: ("true" :: String))
            <> ("limit" =: (1 :: Integer))
        )
    -- https://williamyaoh.com/posts/2019-10-19-a-cheatsheet-to-json-handling.html
    let parsed = fromJSONValue (responseBody r) :: Maybe Push
    liftIO $ print parsed
    pure parsed
    -- liftIO $ print parsed

app :: WS.ClientApp ()
app conn = do
  time <- currentUnixTime
  recentTime <- newIORef time
  putStrLn "Connected!"
  forever $ do
    msg <- WS.receiveData conn
    let received = decode $ BL.pack $ unpack msg :: Maybe RecData
    case received of
      Just a ->
        when (mainType a == "tickle") $ do
          numTime <- readIORef recentTime
          push <- grabPush numTime
          when (isJust push) (do
          newTime <- interrogateResponse (fromJust push) numTime
          writeIORef recentTime newTime)
    print received
    liftIO $ T.putStrLn msg

  WS.sendClose conn ("Bye!" :: Text)

mainLoop :: IO ()
mainLoop = do
  token <- getToken
  WWS.runSecureClient "stream.pushbullet.com" 443 ("/websocket/" <> token) app
