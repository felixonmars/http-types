{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Query strings generally have the following form:
--
-- @"key1=value1&key2=value2" (given a 'Query' of [("key1", Just "value1"), ("key2", Just "value2")])@
--
-- But if the value of @key1@ is 'Nothing', it becomes:
--
-- @key1&key2=value2 (given: [("key1", Nothing), ("key2", Just "value2")])@
--
-- This module also provides type synonyms and functions to handle queries
-- that do not allow/expect key without values. These are the 'SimpleQuery'
-- type and their associated functions.
module Network.HTTP.Types.URI (
    -- * Query strings

    -- ** Query
    QueryItem,
    Query,
    renderQuery,
    renderQueryBuilder,
    parseQuery,
    parseQueryReplacePlus,

    -- *** Query (Text)
    QueryText,
    queryTextToQuery,
    queryToQueryText,
    renderQueryText,
    parseQueryText,

    -- ** SimpleQuery
    SimpleQueryItem,
    SimpleQuery,
    simpleQueryToQuery,
    renderSimpleQuery,
    parseSimpleQuery,

    -- ** PartialEscapeQuery
    PartialEscapeQueryItem,
    PartialEscapeQuery,
    EscapeItem (..),
    renderQueryPartialEscape,
    renderQueryBuilderPartialEscape,

    -- * Path segments
    encodePathSegments,
    decodePathSegments,
    encodePathSegmentsRelative,

    -- * Path (segments + query string)
    extractPath,
    encodePath,
    decodePath,

    -- * URL encoding / decoding
    urlEncodeBuilder,
    urlEncode,
    urlDecode,
)
where

import Control.Arrow (second, (***))
import Data.Bits (shiftL, (.|.))
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as BL
import Data.Char (ord)
import Data.List (intersperse)
import Data.Maybe (fromMaybe)
#if __GLASGOW_HASKELL__ < 710
import Data.Monoid
#endif
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8With, encodeUtf8)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Word (Word8)

-- | An item from the query string, split up into two parts.
--
-- The second part should be 'Nothing' if there was no key-value
-- separator after the query item name.
--
-- /N.B. The most standard key-value separator is the equals sign: @=@,/
-- /but in HTTP forms can sometimes be a semicolon: @;@/
type QueryItem = (B.ByteString, Maybe B.ByteString)

-- | A sequence of 'QueryItem's.
type Query = [QueryItem]

-- | Like Query, but with 'Text' instead of 'B.ByteString' (UTF8-encoded).
type QueryText = [(Text, Maybe Text)]

-- | Convert 'QueryText' to 'Query'.
queryTextToQuery :: QueryText -> Query
queryTextToQuery = map $ encodeUtf8 *** fmap encodeUtf8

-- | Convert 'QueryText' to a 'B.Builder'.
renderQueryText ::
    -- | prepend a question mark?
    Bool ->
    QueryText ->
    B.Builder
renderQueryText b = renderQueryBuilder b . queryTextToQuery

-- | Convert 'Query' to 'QueryText' (leniently decoding the UTF-8).
queryToQueryText :: Query -> QueryText
queryToQueryText =
    map $ go *** fmap go
  where
    go = decodeUtf8With lenientDecode

-- | Parse 'QueryText' from a 'B.ByteString'. See 'parseQuery' for details.
parseQueryText :: B.ByteString -> QueryText
parseQueryText = queryToQueryText . parseQuery

-- | Simplified Query item type without support for parameter-less items.
type SimpleQueryItem = (B.ByteString, B.ByteString)

-- | Simplified Query type without support for parameter-less items.
type SimpleQuery = [SimpleQueryItem]

-- | Convert 'SimpleQuery' to 'Query'.
simpleQueryToQuery :: SimpleQuery -> Query
simpleQueryToQuery = map (second Just)

-- | Convert 'Query' to a 'Builder'.
renderQueryBuilder ::
    -- | prepend a question mark?
    Bool ->
    Query ->
    B.Builder
renderQueryBuilder _ [] = mempty
-- FIXME replace mconcat + map with foldr
renderQueryBuilder qmark' (p : ps) =
    mconcat $
        go (if qmark' then qmark else mempty) p
            : map (go amp) ps
  where
    qmark = B.byteString "?"
    amp = B.byteString "&"
    equal = B.byteString "="
    go sep (k, mv) =
        mconcat
            [ sep
            , urlEncodeBuilder True k
            , case mv of
                Nothing -> mempty
                Just v -> equal `mappend` urlEncodeBuilder True v
            ]

-- | Convert 'Query' to 'ByteString'.
renderQuery ::
    -- | prepend question mark?
    Bool ->
    Query ->
    B.ByteString
renderQuery qm = BL.toStrict . B.toLazyByteString . renderQueryBuilder qm

-- | Convert 'SimpleQuery' to 'ByteString'.
renderSimpleQuery ::
    -- | prepend question mark?
    Bool ->
    SimpleQuery ->
    B.ByteString
renderSimpleQuery useQuestionMark = renderQuery useQuestionMark . simpleQueryToQuery

-- | Split out the query string into a list of keys and values. A few
-- importants points:
--
-- * The result returned is still bytestrings, since we perform no character
-- decoding here. Most likely, you will want to use UTF-8 decoding, but this is
-- left to the user of the library.
--
-- * Percent decoding errors are ignored. In particular, @"%Q"@ will be output as
-- @"%Q"@.
--
-- * It decodes @\'+\'@ characters to @\' \'@
parseQuery :: B.ByteString -> Query
parseQuery = parseQueryReplacePlus True

-- | Same functionality as 'parseQuery' with the option to decode @\'+\'@ characters to @\' \'@
-- or preserve @\'+\'@
parseQueryReplacePlus :: Bool -> B.ByteString -> Query
parseQueryReplacePlus replacePlus bs = parseQueryString' $ dropQuestion bs
  where
    dropQuestion q =
        case B.uncons q of
            Just (63, q') -> q'
            _ -> q
    parseQueryString' q | B.null q = []
    parseQueryString' q =
        let (x, xs) = breakDiscard queryStringSeparators q
         in parsePair x : parseQueryString' xs
      where
        parsePair x =
            let (k, v) = B.break (== 61) x -- equal sign
                v'' =
                    case B.uncons v of
                        Just (_, v') -> Just $ urlDecode replacePlus v'
                        _ -> Nothing
             in (urlDecode replacePlus k, v'')

queryStringSeparators :: B.ByteString
queryStringSeparators = B.pack [38, 59] -- ampersand, semicolon

-- | Break the second bytestring at the first occurrence of any bytes from
-- the first bytestring, discarding that byte.
breakDiscard :: B.ByteString -> B.ByteString -> (B.ByteString, B.ByteString)
breakDiscard seps s =
    let (x, y) = B.break (`B.elem` seps) s
     in (x, B.drop 1 y)

-- | Parse 'SimpleQuery' from a 'ByteString'.
--
-- This uses 'parseQuery' under the hood, and will transform
-- any 'Nothing' values into an empty 'B.ByteString'.
parseSimpleQuery :: B.ByteString -> SimpleQuery
parseSimpleQuery = map (second $ fromMaybe B.empty) . parseQuery

ord8 :: Char -> Word8
ord8 = fromIntegral . ord

unreservedQS, unreservedPI :: [Word8]
unreservedQS = map ord8 "-_.~"
unreservedPI = map ord8 "-_.~:@&=+$,"

-- | Percent-encoding for URLs.
urlEncodeBuilder' :: [Word8] -> B.ByteString -> B.Builder
urlEncodeBuilder' extraUnreserved = mconcat . map encodeChar . B.unpack
  where
    encodeChar ch
        | unreserved ch = B.word8 ch
        | otherwise = h2 ch

    unreserved ch
        | ch >= 65 && ch <= 90 = True -- A-Z
        | ch >= 97 && ch <= 122 = True -- a-z
        | ch >= 48 && ch <= 57 = True -- 0-9
    unreserved c = c `elem` extraUnreserved

    -- must be upper-case
    h2 v = B.word8 37 `mappend` B.word8 (h a) `mappend` B.word8 (h b) -- 37 = %
      where
        (a, b) = v `divMod` 16
    h i
        | i < 10 = 48 + i -- zero (0)
        | otherwise = 65 + i - 10 -- 65: A

-- | Percent-encoding for URLs (using 'B.Builder').
urlEncodeBuilder ::
    -- | Whether input is in query string. True: Query string, False: Path element
    Bool ->
    B.ByteString ->
    B.Builder
urlEncodeBuilder True = urlEncodeBuilder' unreservedQS
urlEncodeBuilder False = urlEncodeBuilder' unreservedPI

-- | Percent-encoding for URLs.
urlEncode ::
    -- | Whether to decode @\'+\'@ to @\' \'@
    Bool ->
    -- | The ByteString to encode as URL
    B.ByteString ->
    -- | The encoded URL
    B.ByteString
urlEncode q = BL.toStrict . B.toLazyByteString . urlEncodeBuilder q

-- | Percent-decoding.
urlDecode ::
    -- | Whether to decode @\'+\'@ to @\' \'@
    Bool ->
    B.ByteString ->
    B.ByteString
urlDecode replacePlus z = fst $ B.unfoldrN (B.length z) go z
  where
    go bs =
        case B.uncons bs of
            Nothing -> Nothing
            -- plus to space
            Just (43, ws) | replacePlus -> Just (32, ws)
            -- percent
            Just (37, ws) -> Just $ fromMaybe (37, ws) $ do
                (x, xs) <- B.uncons ws
                x' <- hexVal x
                (y, ys) <- B.uncons xs
                y' <- hexVal y
                Just (combine x' y', ys)
            Just (w, ws) -> Just (w, ws)
    hexVal w
        | 48 <= w && w <= 57 = Just $ w - 48 -- 0 - 9
        | 65 <= w && w <= 70 = Just $ w - 55 -- A - F
        | 97 <= w && w <= 102 = Just $ w - 87 -- a - f
        | otherwise = Nothing
    combine :: Word8 -> Word8 -> Word8
    combine a b = shiftL a 4 .|. b

-- | Encodes a list of path segments into a valid URL fragment.
--
-- This function takes the following three steps:
--
-- * UTF-8 encodes the characters.
--
-- * Performs percent encoding on all unreserved characters, as well as @\:\@\=\+\$@,
--
-- * Prepends each segment with a slash.
--
-- For example:
--
-- > encodePathSegments [\"foo\", \"bar\", \"baz\"]
-- \"\/foo\/bar\/baz\"
--
-- > encodePathSegments [\"foo bar\", \"baz\/bin\"]
-- \"\/foo\%20bar\/baz\%2Fbin\"
--
-- > encodePathSegments [\"שלום\"]
-- \"\/%D7%A9%D7%9C%D7%95%D7%9D\"
--
-- Huge thanks to Jeremy Shaw who created the original implementation of this
-- function in web-routes and did such thorough research to determine all
-- correct escaping procedures.
encodePathSegments :: [Text] -> B.Builder
encodePathSegments = foldr (\x -> mappend (B.byteString "/" `mappend` encodePathSegment x)) mempty

-- | Like encodePathSegments, but without the initial slash.
encodePathSegmentsRelative :: [Text] -> B.Builder
encodePathSegmentsRelative xs = mconcat $ intersperse (B.byteString "/") (map encodePathSegment xs)

encodePathSegment :: Text -> B.Builder
encodePathSegment = urlEncodeBuilder False . encodeUtf8

-- | Parse a list of path segments from a valid URL fragment.
decodePathSegments :: B.ByteString -> [Text]
decodePathSegments "" = []
decodePathSegments "/" = []
decodePathSegments a =
    go $ drop1Slash a
  where
    drop1Slash bs =
        case B.uncons bs of
            Just (47, bs') -> bs' -- 47 == /
            _ -> bs
    go bs =
        let (x, y) = B.break (== 47) bs
         in decodePathSegment x
                : if B.null y
                    then []
                    else go $ B.drop 1 y

decodePathSegment :: B.ByteString -> Text
decodePathSegment = decodeUtf8With lenientDecode . urlDecode False

-- | Extract whole path (path segments + query) from a
-- <http://tools.ietf.org/html/rfc2616#section-5.1.2 RFC 2616 Request-URI>.
--
-- >>> extractPath "/path"
-- "/path"
--
-- >>> extractPath "http://example.com:8080/path"
-- "/path"
--
-- >>> extractPath "http://example.com"
-- "/"
--
-- >>> extractPath ""
-- "/"
extractPath :: B.ByteString -> B.ByteString
extractPath = ensureNonEmpty . extract
  where
    extract path
        | "http://" `B.isPrefixOf` path = (snd . breakOnSlash . B.drop 7) path
        | "https://" `B.isPrefixOf` path = (snd . breakOnSlash . B.drop 8) path
        | otherwise = path
    breakOnSlash = B.break (== 47)
    ensureNonEmpty "" = "/"
    ensureNonEmpty p = p

-- | Encode a whole path (path segments + query).
encodePath :: [Text] -> Query -> B.Builder
encodePath x [] = encodePathSegments x
encodePath x y = encodePathSegments x `mappend` renderQueryBuilder True y

-- | Decode a whole path (path segments + query).
decodePath :: B.ByteString -> ([Text], Query)
decodePath b =
    let (x, y) = B.break (== 63) b -- question mark
     in (decodePathSegments x, parseQuery y)

-----------------------------------------------------------------------------------------

-- | For some URIs characters must not be URI encoded,
-- e.g. @\'+\'@ or @\':\'@ in @q=a+language:haskell+created:2009-01-01..2009-02-01&sort=stars@
-- The character list unreservedPI instead of unreservedQS would solve this.
-- But we explicitly decide what part to encode.
-- This is mandatory when searching for @\'+\'@: @q=%2B+language:haskell@.
data EscapeItem
    = QE B.ByteString -- will be URL encoded
    | QN B.ByteString -- will not be url encoded, e.g. @\'+\'@ or @\':\'@
    deriving (Show, Eq, Ord)

-- | Query item
type PartialEscapeQueryItem = (B.ByteString, [EscapeItem])

-- | Query with some chars that should not be escaped.
--
-- General form: @a=b&c=d:e+f&g=h@
type PartialEscapeQuery = [PartialEscapeQueryItem]

-- | Convert 'PartialEscapeQuery' to 'ByteString'.
renderQueryPartialEscape ::
    -- | prepend question mark?
    Bool ->
    PartialEscapeQuery ->
    B.ByteString
renderQueryPartialEscape qm = BL.toStrict . B.toLazyByteString . renderQueryBuilderPartialEscape qm

-- | Convert 'PartialEscapeQuery' to a 'Builder'.
renderQueryBuilderPartialEscape ::
    -- | prepend a question mark?
    Bool ->
    PartialEscapeQuery ->
    B.Builder
renderQueryBuilderPartialEscape _ [] = mempty
-- FIXME replace mconcat + map with foldr
renderQueryBuilderPartialEscape qmark' (p : ps) =
    mconcat $
        go (if qmark' then qmark else mempty) p
            : map (go amp) ps
  where
    qmark = B.byteString "?"
    amp = B.byteString "&"
    equal = B.byteString "="
    go sep (k, mv) =
        mconcat
            [ sep
            , urlEncodeBuilder True k
            , case mv of
                [] -> mempty
                vs -> equal `mappend` mconcat (map encode vs)
            ]
    encode (QE v) = urlEncodeBuilder True v
    encode (QN v) = B.byteString v
