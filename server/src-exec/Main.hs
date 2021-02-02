{-# LANGUAGE RecordWildCards #-}

module Main where

import           Control.Exception
import           Data.Int                    (Int64)
import           Control.Monad.Trans.Managed (ManagedT(..), lowerManagedT)
import           Data.Text.Conversions       (convertText)
import           Data.Time.Clock.POSIX       (getPOSIXTime)

import           Hasura.App
import           Hasura.Logging              (Hasura)
import           Hasura.Prelude
import           Hasura.RQL.DDL.Metadata     (fetchMetadata)
import           Hasura.RQL.DDL.Schema
import           Hasura.RQL.Types
import           Hasura.Server.Init
import           Hasura.Server.Migrate       (downgradeCatalog, dropCatalog)
import           Hasura.Server.Version

import qualified Control.Concurrent.Extended as C
import qualified Data.ByteString.Char8      as BC
import qualified Data.ByteString.Lazy       as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Environment           as Env
import qualified Database.PG.Query          as Q
import qualified Hasura.GC                  as GC
import qualified Hasura.Tracing             as Tracing
import qualified System.Exit                as Sys
import qualified System.Metrics             as EKG
import qualified System.Posix.Signals       as Signals

main :: IO ()
main = do
  tryExit $ do
    args <- parseArgs
    env  <- Env.getEnvironment
    unAppM (runApp env args)
  where
    tryExit io = try io >>= \case
      Left (ExitException _code msg) -> BC.putStrLn msg >> Sys.exitFailure
      Right r -> return r

runApp :: Env.Environment -> HGEOptions Hasura -> AppM ()
runApp env (HGEOptionsG rci hgeCmd) =
  withVersion $$(getVersionFromEnvironment) $ case hgeCmd of
    HCServe serveOptions -> do
      runManagedT (initialiseCtx env hgeCmd rci) $ \(initCtx, initTime) -> do
        
        ekgStore <- liftIO do
          s <- EKG.newStore
          EKG.registerGcMetrics s

          let getTimeMs :: IO Int64
              getTimeMs = (round . (* 1000)) `fmap` getPOSIXTime

          EKG.registerCounter "ekg.server_timestamp_ms" getTimeMs s
          pure s
        serverMetrics <- liftIO $ createServerMetrics ekgStore
        
        -- Catches the SIGTERM signal and initiates a graceful shutdown.
        -- Graceful shutdown for regular HTTP requests is already implemented in
        -- Warp, and is triggered by invoking the 'closeSocket' callback.
        -- We only catch the SIGTERM signal once, that is, if the user hits CTRL-C
        -- once again, we terminate the process immediately.
        _ <- liftIO $ Signals.installHandler
          Signals.sigTERM
          (Signals.CatchOnce (shutdownGracefully initCtx))
          Nothing
          
        let Loggers _ logger _ = _icLoggers initCtx
        _idleGCThread <- liftIO $ C.forkImmortal "ourIdleGC" logger $
          GC.ourIdleGC logger (seconds 0.3) (seconds 10) (seconds 60)
        
        lowerManagedT $
          runHGEServer env serveOptions initCtx Nothing initTime Nothing serverMetrics ekgStore

    HCExport -> do
      runManagedT (initialiseCtx env hgeCmd rci) $ \(initCtx, _) -> do
        res <- runTx' initCtx fetchMetadata Q.ReadCommitted
        either (printErrJExit MetadataExportError) printJSON res

    HCClean -> do
      runManagedT (initialiseCtx env hgeCmd rci) $ \(initCtx, _) -> do
        res <- runTx' initCtx dropCatalog Q.ReadCommitted
        either (printErrJExit MetadataCleanError) (const cleanSuccess) res

    HCExecute -> do
      runManagedT (initialiseCtx env hgeCmd rci) $ \(InitCtx{..}, _) -> do
        queryBs <- liftIO BL.getContents
        let sqlGenCtx = SQLGenCtx False
        res <- runAsAdmin _icPgPool sqlGenCtx _icHttpManager $ do
          schemaCache <- buildRebuildableSchemaCache env
          execQuery env queryBs
            & Tracing.runTraceTWithReporter Tracing.noReporter "execute"
            & runHasSystemDefinedT (SystemDefined False)
            & runCacheRWT schemaCache
            & fmap (\(res, _, _) -> res)
        either (printErrJExit ExecuteProcessError) (liftIO . BLC.putStrLn) res

    HCDowngrade opts -> do
      runManagedT (initialiseCtx env hgeCmd rci) $ \(InitCtx{..}, initTime) -> do
        let sqlGenCtx = SQLGenCtx False
        res <- downgradeCatalog opts initTime
               & runAsAdmin _icPgPool sqlGenCtx _icHttpManager
        either (printErrJExit DowngradeProcessError) (liftIO . print) res

    HCVersion -> liftIO $ putStrLn $ "Hasura GraphQL Engine: " ++ convertText currentVersion
  where
    runTx' initCtx tx txIso =
      liftIO $ runExceptT $ Q.runTx (_icPgPool initCtx) (txIso, Nothing) tx

    cleanSuccess = liftIO $ putStrLn "successfully cleaned graphql-engine related data"
