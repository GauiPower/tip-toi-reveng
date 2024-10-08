module OidCode (genRawPixels, oidSVGPattern, writeRawPNG, writeRawSVG, tilePixelSize, DPI(..), PixelSize(..)) where

import Data.Word
import Data.Bits
import qualified Data.ByteString.Lazy as B
import Control.Monad
import Codec.Picture
import Codec.Picture.Types
import Codec.Picture.Metadata
import Control.Monad.ST
import Data.Vector.Storable.ByteString
import qualified Data.ByteString.Base64.Lazy
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import Utils
import Types

import qualified Text.Blaze.Svg as S
import qualified Text.Blaze.Svg11 as S
import qualified Text.Blaze.Svg11.Attributes as A
import Text.Blaze.Svg11 ((!))
import Text.Blaze.Svg.Renderer.Utf8
import Text.Printf
import Control.Arrow


-- Image generation

checksum :: Word16 -> Word16
checksum dec = c3
  where
    c1  =       (((dec >> 2) ^ (dec >> 8) ^ (dec >> 12) ^ (dec >> 14)) & 0x01) << 1
    c2 = c1 .|. (((dec) ^ (dec >> 4) ^ (dec >>  6) ^ (dec >> 10)) & 0x01)
    c3 = c2  ^  0x02

    (>>) = shiftR
    (<<) = shiftL
    (^) = xor
    (&) = (.&.)

oidSVG :: Conf -> Bool -> String -> Word16 -> S.Svg
oidSVG conf usePNG title code =
    S.docTypeSvg ! A.version (S.stringValue "1.1")
                 ! A.width (S.stringValue (printf "%umm" w))
                 ! A.height (S.stringValue (printf "%umm" h))
                 ! A.viewbox (S.stringValue (printf "0 0 %u %u" (w*48) (h*48))) $ do
        S.defs (oidSVGPattern conf usePNG title code)
        S.rect
            ! A.width (S.toValue (w*48))
            ! A.height (S.toValue (h*48))
            ! A.fill (S.toValue $ "url(#"++title++")")
  where
    (w,h) = cCodeDim conf

-- Create an OID pattern with the given id of the given code
-- This assumes 48 dots per mm.
oidSVGPattern :: Conf -> Bool -> String -> Word16 -> S.Svg
oidSVGPattern conf usePNG title code =
  S.pattern ! A.width (S.toValue "48")
            ! A.height (S.toValue "48")
            ! A.id_ (S.toValue title)
            ! A.patternunits (S.toValue "userSpaceOnUse") $
  oidSVGPatternContent conf usePNG title code

oidSVGPatternContent :: Conf -> Bool -> String -> Word16 -> S.Svg
oidSVGPatternContent conf True title code =
    S.image ! A.width (S.toValue "48")
            ! A.height (S.toValue "48")
            ! A.xlinkHref (S.toValue (T.pack "data:image/png;base64," <> pngBase64))
  where
    png = genRawPNG 48 48 (conf { cDPI = 1200 }) title code
    pngBase64 = T.decodeUtf8 $ B.toStrict $
        Data.ByteString.Base64.Lazy.encode png

oidSVGPatternContent _conf False _title code = f (0,0)
  where
    quart 8 = checksum code
    quart n = (code `div` 4^n) `mod` 4

    f :: (Integer, Integer) -> S.Svg
    f = mconcat $ map position $
        zip (flip (,) <$> [3,2,1] <*> [3,2,1])
            [ value (quart n) | n <- [0..8] ] ++
        [ (p, plain) | p <- [(0,0), (1,0), (2,0), (3,0), (0,1), (0,3) ] ] ++
        [ ((0,2), special) ]

    -- pixel = S.rect ! A.width (S.toValue "2") ! A.height (S.toValue "2") ! pos (7,7)
    pixel (x,y) = S.path ! A.d path
      where path = S.mkPath $ do
                S.m (x+5) (y+5)
                S.hr 2
                S.vr 2
                S.hr (-2)
                S.z

    plain = pixel
    value 0 = at (2,2)   plain
    value 1 = at (-2,2)  plain
    value 2 = at (-2,-2) plain
    value 3 = at (2,-2)  plain
    value _ = error "value: unexpected param"
    special = at (3,0)   plain

    position ((n,m), p) = at (n*12, m*12) p

    -- Drawing combinators
    at (x, y) f = f . ((+x) *** (+y))

writeRawSVG :: Conf -> Bool -> String -> Word16 -> FilePath -> IO ()
writeRawSVG conf usePNG title code filename =
    B.writeFile filename $
    renderSvg (oidSVG conf usePNG title code)

type DPI = Int
type PixelSize = Int

imageFromBlackPixels :: ColorConvertible PixelYA8 p => Int -> Int -> [(Int, Int)] -> Image p
imageFromBlackPixels width height pixels = runST $ do
    i <- createMutableImage width height background
    forM_ pixels $ \(x,y) -> do
        writePixel i x y black
    freezeImage i
  where
    black =      promotePixel $ PixelYA8 minBound maxBound
    background = promotePixel $ PixelYA8 maxBound minBound

-- | Size of one tile, in pixels
tilePixelSize :: DPI -> PixelSize -> Int
tilePixelSize dpi _ps = width
  where
    spacePerPoint = dpi `div2` 100
    width  = 4*spacePerPoint

-- | Renders a single OID Image, returns its dimensions and the black pixels therein
singeOidImage :: Conf -> Word16 -> ((Int, Int), [(Int, Int)])
singeOidImage conf code = ((width, height), pixels)
  where
    dpi = cDPI conf
    ps = cPixelSize conf

    spacePerPoint = dpi `div2` 100
    width  = 4*spacePerPoint
    height = 4*spacePerPoint

    pixels = mconcat $ map position $
        zip (flip (,) <$> [3,2,1] <*> [3,2,1])
            [ value (quart n) | n <- [0..8] ] ++
        [ (p, centeredDot) | p <- [(0,0), (1,0), (2,0), (3,0), (0,1), (0,3) ] ] ++
        [ ((0,2), special) ]


    quart 8 = checksum code
    quart n = (code `div` 4^n) `mod` 4


    dot = [(x,y) | x <- [1..ps], y <- [1..ps]]

    centeredDot | xshift < 0 || yshift < 0 = error "Dots too large. Try a smaller pixel size"
                | otherwise = at (xshift, yshift) dot
      where xshift = (spacePerPoint - ps) `div` 2 - 1
            yshift = (spacePerPoint - ps) `div` 2 - 1

    -- | how many pixels to shift dots horizontally
    s  = dpi `div2` 600
    -- | how many pixels to shift the special dot horizontally
    ss = dpi `div2` 400

    value 0 = at ( s, s) centeredDot
    value 1 = at (-s, s) centeredDot
    value 2 = at (-s,-s) centeredDot
    value 3 = at ( s,-s) centeredDot
    value _ = error "value: unexpected param"
    special = at (ss,0)  centeredDot

    position ((n,m), p) = at (n*spacePerPoint, m*spacePerPoint) p

    -- Drawing combinators
    at (x, y) = map (\(x', y') -> (x + x', y + y'))

-- integer division rounded up
x `div2` y = ((x-1) `div` y) + 1

oidImage :: ColorConvertible PixelYA8 p => Int -> Int -> Conf -> Word16 -> Image p
oidImage w h conf code =
    imageFromBlackPixels w h tiledPixels
  where
    ((cw,ch), pixels) = singeOidImage conf code

    tiledPixels =
        [ (x',y')
        | (x,y) <- pixels
        , x' <- [x,x + cw..w-1]
        , y' <- [y,y + ch..h-1]
        ]
-- Width and height in pixels
genRawPixels :: Int -> Int -> Conf -> Word16 -> B.ByteString
genRawPixels w h conf code =
    -- All very shaky here, but it seems to work
    B.fromStrict $
    vectorToByteString $
    imageData $
    (oidImage w h conf code :: Image PixelRGB8)

cCodeDimPixels :: Conf -> (Int, Int)
cCodeDimPixels conf = (w',h')
  where
    (w,h) = cCodeDim conf
    -- 25.4mm per inch
    w' = round $ fromIntegral (w * cDPI conf) / 25.4
    h' = round $ fromIntegral (h * cDPI conf) / 25.4

writeRawPNG :: Conf -> String -> Word16 -> FilePath -> IO ()
writeRawPNG conf title code filename =
    B.writeFile filename $
    genRawPNG w h conf title code
  where
    (w,h) = cCodeDimPixels conf


genRawPNG :: Int -> Int -> Conf -> String -> Word16 -> B.ByteString
genRawPNG w h conf title code =
    encodePngWithMetadata metadata $
    (oidImage w h conf code :: Image PixelYA8)
  where
    metadata = mconcat
        [ singleton DpiX (fromIntegral (cDPI conf))
        , singleton DpiY (fromIntegral (cDPI conf))
        , singleton Title title
        , singleton Software $ "tttool " ++ tttoolVersion
        ]
