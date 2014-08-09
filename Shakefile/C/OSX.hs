-- Copyright 2012-2013 Samplecount S.L.
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

module Shakefile.C.OSX (
    DeveloperPath
  , getDeveloperPath
  , getLatestPlatform
  , macOSX
  , iPhoneOS
  , iPhoneSimulator
  , target
  , getDefaultToolChain
  , sdkVersion
  , toolChain
  , macosx_version_min
  , iphoneos_version_min
  , universalBinary
) where

import           Control.Applicative
import           Data.List (stripPrefix)
import           Data.List.Split (splitOn)
import           Data.Version (Version(..), showVersion)
import           Development.Shake as Shake
import           Development.Shake.FilePath
import           Shakefile.C
import           Shakefile.Label (append, get, prepend, set)
import qualified System.Directory as Dir
import           System.Process (readProcess)

archFlags :: Target -> [String]
archFlags t = ["-arch", archString (targetArch t)]

newtype DeveloperPath = DeveloperPath { developerPath :: FilePath } deriving (Show)

-- | Get base path of development tools on OSX.
getDeveloperPath :: IO DeveloperPath
getDeveloperPath =
  (DeveloperPath . head . splitOn "\n")
    <$> readProcess "xcode-select" ["--print-path"] ""

sdkDirectory :: DeveloperPath -> String -> FilePath
sdkDirectory developer platform =
      developerPath developer
  </> "Platforms"
  </> (platform ++ ".platform")
  </> "Developer"
  </> "SDKs"

macOSX :: Platform
macOSX = Platform "MacOSX"

iPhoneOS :: Platform
iPhoneOS = Platform "iPhoneOS"

iPhoneSimulator :: Platform
iPhoneSimulator = Platform "iPhoneSimulator"

target :: Platform -> Arch -> Target
target = Target OSX

platformSDKPath :: DeveloperPath -> Platform -> Version -> FilePath
platformSDKPath developer platform version =
      sdkDirectory developer (platformName platform)
  </> platformName platform ++ showVersion version ++ ".sdk"

getLatestPlatform :: DeveloperPath -> (Version -> Platform) -> IO Platform
getLatestPlatform developer mkPlatform = do
  dirs <- Dir.getDirectoryContents $ sdkDirectory developer name
  let maxVersion = case [ x | Just x <- map (fmap (  map read {- slip in an innocent read, can't fail, can it? -}
                                                   . splitOn "."
                                                   . dropExtension)
                                                  . stripPrefix name)
                                            dirs ] of
                      [] -> error $ "OSX: No SDK found for " ++ name
                      xs -> maximum xs
  return $ mkPlatform $ Version maxVersion []
  where name = platformName (mkPlatform (Version [] []))

-- | Get OSX system version (first two digits).
getSystemVersion :: IO Version
getSystemVersion =
  flip Version []
    <$> (map read . take 2 . splitOn ".")
    <$> readProcess "sw_vers" ["-productVersion"] ""

getDefaultToolChain :: IO (Target, Action ToolChain)
getDefaultToolChain = do
    let defaultTarget = target macOSX (X86 X86_64)
    return ( defaultTarget
           , toolChain
               <$> liftIO getDeveloperPath
               <*> liftIO getSystemVersion
               <*> pure defaultTarget )

sdkVersion :: Int -> Int -> Version
sdkVersion major minor = Version [major, minor] []

toolChain :: DeveloperPath -> Version -> Target -> ToolChain
toolChain developer version t =
    set variant LLVM
  $ set toolDirectory (Just (developerPath developer </> "Toolchains/XcodeDefault.xctoolchain/usr/bin"))
  $ set compilerCommand "clang"
  $ set archiverCommand "libtool"
  $ set archiver (\tc flags inputs output -> do
      need inputs
      command_ [] (tool tc archiverCommand)
        $  get archiverFlags flags
        ++ ["-static"]
        ++ ["-o", output]
        ++ inputs
    )
  $ set linkerCommand "clang++"
  $ set linker (\lr tc ->
      case lr of
        Executable      -> defaultLinker tc
        SharedLibrary   -> defaultLinker tc . prepend linkerFlags ["-dynamiclib"]
        LoadableLibrary -> defaultLinker tc . prepend linkerFlags ["-bundle"]
    )
  $ set defaultBuildFlags ( append preprocessorFlags [ "-isysroot", sysRoot ]
                          . append compilerFlags [(Nothing, archFlags t)]
                          . append linkerFlags (archFlags t ++ [ "-isysroot", sysRoot ]) )
  $ defaultToolChain
  where sysRoot = platformSDKPath developer (targetPlatform t) version

macosx_version_min :: Version -> BuildFlags -> BuildFlags
macosx_version_min version =
  append compilerFlags [(Nothing, ["-mmacosx-version-min=" ++ showVersion version])]

iphoneos_version_min :: Version -> BuildFlags -> BuildFlags
iphoneos_version_min version =
  append compilerFlags [(Nothing, ["-miphoneos-version-min=" ++ showVersion version])]

universalBinary :: [FilePath] -> FilePath -> Rules FilePath
universalBinary inputs output = do
    output ?=> \_ -> do
        need inputs
        command_ [] "lipo" $ ["-create", "-output", output] ++ inputs
    return output
