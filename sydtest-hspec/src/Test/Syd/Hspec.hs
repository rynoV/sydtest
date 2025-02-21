{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}

module Test.Syd.Hspec (fromHspec) where

import Control.Exception
import Control.Monad.Writer
import Data.List
import qualified Test.Hspec.Core.Spec as Hspec
import Test.Syd as Syd

-- | Import an Hspec 'Test.Hspec.Spec' as a Sydtest 'Test.Syd.Spec'.
--
-- The reasoning behind this function is that, eventhough migration from hspec
-- to sydtest is usually very simple, you might depend on certain libraries
-- beyond your control that still use hspec.  In that case you want to be able
-- to still use those libraries but also use sydtest already.
--
-- For this reason, and because hspec doesn't tell you wether a test is pending
-- until after you run it, pending tests are imported as passing tests.
fromHspec :: Hspec.Spec -> Syd.Spec
fromHspec (Hspec.SpecM specWriter) = do
  (result, trees) <- liftIO $ runWriterT specWriter
  mapM_ importSpecTree trees
  pure result

importSpecTree :: Hspec.SpecTree () -> Syd.Spec
importSpecTree = go
  where
    go = \case
      Hspec.Leaf item -> importItem item
      Hspec.Node d ts -> describe d $ mapM_ go ts
      -- Hspec.NodeWithCleanup's semantics are so weird that we can only do
      -- this translation if inner equals ().
      Hspec.NodeWithCleanup cleanup ts -> afterAll_ (cleanup ()) $ mapM_ go ts

importItem :: forall inner. Hspec.Item inner -> Syd.TestDefM '[] inner ()
importItem item@Hspec.Item {..} =
  let parallelMod = case itemIsParallelizable of
        Just True -> parallel
        Just False -> sequential
        Nothing -> id
   in parallelMod $
        it itemRequirement (ImportedItem item :: ImportedItem inner)

newtype ImportedItem a = ImportedItem (Hspec.Item a)

instance IsTest (ImportedItem a) where
  type Arg1 (ImportedItem a) = ()
  type Arg2 (ImportedItem a) = a
  runTest = runImportedItem

runImportedItem ::
  ImportedItem inner ->
  TestRunSettings ->
  ((() -> inner -> IO ()) -> IO ()) ->
  IO TestRunResult
runImportedItem (ImportedItem Hspec.Item {..}) trs wrapper = do
  errOrRes <- applyWrapper2 wrapper $ \() inner -> do
    let params :: Hspec.Params
        params =
          Hspec.Params
            { Hspec.paramsQuickCheckArgs = makeQuickCheckArgs trs,
              -- TODO use the right depth when sydtest supports smallcheck
              Hspec.paramsSmallCheckDepth = Hspec.paramsSmallCheckDepth Hspec.defaultParams
            }
        callback :: Hspec.ProgressCallback
        callback = const $ pure ()
    itemExample params (\takeInner -> takeInner inner) callback
  let (testRunResultStatus, testRunResultException) = case errOrRes of
        Left ex -> (TestFailed, Just ex)
        Right result -> case Hspec.resultStatus result of
          Hspec.Success -> (TestPassed, Nothing)
          -- This is certainly a debatable choice, but there's no need to make
          -- tests fail here, and there's no way to know ahead of time whether
          -- a test is pending so we have no choice.
          Hspec.Pending _ _ -> (TestPassed, Nothing)
          Hspec.Failure mloc fr ->
            let withExtraContext :: Maybe String -> Assertion -> Assertion
                withExtraContext = maybe id (\extraContext a -> Context a extraContext)
                niceLocation :: Hspec.Location -> String
                niceLocation Hspec.Location {..} = intercalate ":" [locationFile, show locationLine, show locationColumn]
                withLocationContext :: Assertion -> Assertion
                withLocationContext = withExtraContext $ niceLocation <$> mloc
                assertion = case fr of
                  Hspec.NoReason -> Right $ ExpectationFailed "Hspec had no more information about this failure."
                  Hspec.Reason s -> Right $ ExpectationFailed s
                  Hspec.ExpectedButGot mExtraContext expected actual -> Right $ withExtraContext mExtraContext $ NotEqualButShouldHaveBeenEqual actual expected
                  Hspec.Error mExtraContext e -> withExtraContext mExtraContext <$> Left (displayException e)
             in ( TestFailed,
                  Just
                    ( Context
                        <$> ( withLocationContext <$> assertion
                            )
                          <*> pure
                            (Hspec.resultInfo result)
                    )
                )
  let testRunResultNumTests = Nothing
  let testRunResultNumShrinks = Nothing
  let testRunResultRetries = Nothing
  let testRunResultGoldenCase = Nothing
  let testRunResultFailingInputs = []
  let testRunResultExtraInfo = Nothing
  let testRunResultLabels = Nothing
  let testRunResultClasses = Nothing
  let testRunResultTables = Nothing
  let testRunResultFlakinessMessage = Nothing

  pure TestRunResult {..}
