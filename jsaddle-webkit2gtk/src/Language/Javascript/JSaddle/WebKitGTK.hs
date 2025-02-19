{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MonoLocalBinds #-}
-----------------------------------------------------------------------------
--
-- Module      :  Language.Javascript.JSaddle.WebSockets
-- Copyright   :  (c) Hamish Mackenzie
-- License     :  MIT
--
-- Maintainer  :  Hamish Mackenzie <Hamish.K.Mackenzie@googlemail.com>
--
-- |
--
-----------------------------------------------------------------------------
module Language.Javascript.JSaddle.WebKitGTK (
  -- * Running JSM in a WebView
    run
#ifndef ghcjs_HOST_OS
  , runInWebView
#endif
  ) where

#ifdef ghcjs_HOST_OS

run :: IO () -> IO ()
run = id
{-# INLINE run #-}

#else

import Control.Monad (void)
import Control.Monad.IO.Class (MonadIO(..), MonadIO)
import Control.Concurrent (forkIO, yield)

#ifndef mingw32_HOST_OS
import System.Posix.Signals (installHandler, keyboardSignal, Handler(Catch))
#endif
import System.Directory (getCurrentDirectory)

import Data.Monoid ((<>))
import Data.ByteString.Lazy (toStrict, fromStrict)
import qualified Data.ByteString.Lazy as LB (ByteString)
import Data.Aeson (encode, decode)
import qualified Data.Text as T (pack)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)

import Data.GI.Base.BasicTypes (GObject)
import Data.GI.Base.Signals
       (connectSignalFunPtr, SignalConnectMode(..), SignalConnectMode,
        SignalHandlerId)

import GI.GLib (timeoutAdd, idleAdd, pattern PRIORITY_HIGH, pattern PRIORITY_DEFAULT)
import qualified GI.Gtk as Gtk (main, init)
import GI.Gtk
       (windowSetPosition, windowSetDefaultSize, windowNew,
        scrolledWindowNew, Adjustment, containerAdd,
        WindowType(..), WindowPosition(..), widgetDestroy,
        widgetGetToplevel, widgetShowAll, onWidgetDestroy,
        mainQuit)
import GI.Gio (Cancellable)
import GI.JavaScriptCore (valueToString)
import GI.WebKit2
       (scriptDialogPromptSetText, scriptDialogPromptGetDefaultText,
        scriptDialogGetMessage, scriptDialogGetDialogType,
        onWebViewScriptDialog, WebView,
        setSettingsEnableWriteConsoleMessagesToStdout,
        setSettingsEnableJavascript, webViewNewWithUserContentManager,
        userContentManagerNew,
        userContentManagerRegisterScriptMessageHandler,
        javascriptResultGetJsValue,
        webViewGetUserContentManager,
        webViewRunJavascript, LoadEvent(..),
        UserContentManagerScriptMessageReceivedCallback, webViewLoadHtml,
        onWebViewLoadChanged, setSettingsEnableDeveloperExtras,
        webViewSetSettings, webViewGetSettings, ScriptDialogType(..), IsUserContentManager)
import qualified GI.WebKit2

import Language.Javascript.JSaddle (JSM, Results, Batch)
import Language.Javascript.JSaddle.Run (runJavaScript)
import Language.Javascript.JSaddle.Run.Files (initState, runBatch, ghcjsHelpers)

noAdjustment :: Maybe Adjustment
noAdjustment = Nothing

noCancellable :: Maybe Cancellable
noCancellable = Nothing

quitWebView :: WebView -> IO ()
quitWebView wv = postGUIAsync $ do w <- widgetGetToplevel wv --TODO: Shouldn't this be postGUISync?
                                   widgetDestroy w

installQuitHandler :: WebView -> IO ()
#ifdef mingw32_HOST_OS
installQuitHandler wv = return () -- TODO: Maybe figure something out here for Windows users.
#else
installQuitHandler wv = void $ installHandler keyboardSignal (Catch (quitWebView wv)) Nothing
#endif

postGUIAsync :: IO () -> IO ()
postGUIAsync action =
  void . idleAdd PRIORITY_DEFAULT $ action >> return False

run :: JSM () -> IO ()
run main = do
    _ <- Gtk.init Nothing
    window <- windowNew WindowTypeToplevel
    _ <- timeoutAdd PRIORITY_HIGH 10 (yield >> return True)
    windowSetDefaultSize window 900 600
    windowSetPosition window WindowPositionCenter
    scrollWin <- scrolledWindowNew noAdjustment noAdjustment
    contentManager <- userContentManagerNew
    webView <- webViewNewWithUserContentManager contentManager
    settings <- webViewGetSettings webView
    -- setSettingsEnableUniversalAccessFromFileUris settings True
    setSettingsEnableDeveloperExtras settings True
    setSettingsEnableJavascript settings True
    setSettingsEnableWriteConsoleMessagesToStdout settings True
    webViewSetSettings webView settings
    window `containerAdd` scrollWin
    scrollWin `containerAdd` webView
    _ <- onWidgetDestroy window mainQuit
    widgetShowAll window
    pwd <- getCurrentDirectory
    let webViewLoadChangedCallback LoadEventFinished = runInWebView main webView
        webViewLoadChangedCallback _                 = return ()
    void $ onWebViewLoadChanged webView webViewLoadChangedCallback
    webViewLoadHtml webView "" . Just $ "file://" <> T.pack pwd <> "/index.html"
    installQuitHandler webView
    Gtk.main

runInWebView :: JSM () -> WebView -> IO ()
runInWebView f webView = do
    (processResults, syncResults, start) <- runJavaScript (\batch -> postGUIAsync $
        webViewRunJavascript webView (decodeUtf8 . toStrict $ "runJSaddleBatch(" <> encode batch <> ");") noCancellable Nothing)
        f

    addJSaddleHandler webView processResults syncResults
    webViewRunJavascript webView (decodeUtf8 $ toStrict jsaddleJs) noCancellable . Just $
        \_obj _asyncResult _data ->
            void $ forkIO start

onUserContentManagerScriptMessageReceived :: (IsUserContentManager a, MonadIO m) => a -> UserContentManagerScriptMessageReceivedCallback -> m SignalHandlerId
#if MIN_VERSION_haskell_gi_base(0,26,0)
onUserContentManagerScriptMessageReceived obj cb = GI.WebKit2.onUserContentManagerScriptMessageReceived obj Nothing cb
#else
onUserContentManagerScriptMessageReceived obj cb = liftIO $ connectUserContentManagerScriptMessageReceived obj cb SignalConnectBefore

connectUserContentManagerScriptMessageReceived :: (GObject a, MonadIO m) =>
                                                  a -> UserContentManagerScriptMessageReceivedCallback -> SignalConnectMode -> m SignalHandlerId
connectUserContentManagerScriptMessageReceived obj cb after = liftIO $ do
    let cb' = GI.WebKit2.wrap_UserContentManagerScriptMessageReceivedCallback cb
    cb'' <- GI.WebKit2.mk_UserContentManagerScriptMessageReceivedCallback cb'
    connectSignalFunPtr obj "script-message-received::jsaddle" cb'' after
#if MIN_VERSION_haskell_gi_base(0,23,0)
      Nothing
#endif
#endif

addJSaddleHandler :: WebView -> (Results -> IO ()) -> (Results -> IO Batch) -> IO ()
addJSaddleHandler webView processResult syncResults = do
    manager <- webViewGetUserContentManager webView
    _ <- onUserContentManagerScriptMessageReceived manager $ \result -> do
        arg <- javascriptResultGetJsValue result
        bs <- encodeUtf8 <$> valueToString arg
        mapM_ processResult (decode (fromStrict bs))
    _ <- onWebViewScriptDialog webView $ \dialog ->
        scriptDialogGetDialogType dialog >>= \case
            ScriptDialogTypePrompt ->
                scriptDialogGetMessage dialog >>= \case
                    "JSaddleSync" -> do
                        resultsText <- scriptDialogPromptGetDefaultText dialog
                        case decode (fromStrict $ encodeUtf8 resultsText) of
                            Just results -> do
                                batch <- syncResults results
                                scriptDialogPromptSetText dialog (decodeUtf8 . toStrict $ encode batch)
                                return True
                            Nothing -> return False
                    _ -> return False
            _ -> return False

    void $ userContentManagerRegisterScriptMessageHandler manager "jsaddle"

jsaddleJs :: LB.ByteString
jsaddleJs = ghcjsHelpers <> mconcat
    [ "runJSaddleBatch = (function() {\n"
    , initState
    , "\nreturn function(batch) {\n"
    , runBatch (\a -> "window.webkit.messageHandlers.jsaddle.postMessage(JSON.stringify(" <> a <> "));\n")
               (Just (\a -> "JSON.parse(window.prompt(\"JSaddleSync\", JSON.stringify(" <> a <> ")))"))
    , "};\n"
    , "})()"
    ]

#endif
