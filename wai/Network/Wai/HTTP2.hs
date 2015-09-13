{-# LANGUAGE OverloadedStrings, RankNTypes #-}
{-# LANGUAGE CPP #-}

-- | An HTTP\/2-aware variant of the 'Network.Wai.Application' type.  Compared
-- to the original, this exposes the new functionality of server push and
-- trailers, allows stream fragments to be sent in the form of file ranges, and
-- allows the stream body to produce a value to be used in constructing the
-- trailers.  Existing @Applications@ can be faithfully upgraded to HTTP\/2
-- with 'promoteApplication' or served transparently over both protocols with
-- the normal Warp 'Network.Wai.Handler.Warp.run' family of functions.
--
-- An 'HTTP2Application' takes a 'Request' and a 'PushFunc' and produces a
-- 'Responder' that will push any associated resources and send the response
-- body.  The response is always a stream of 'Builder's and file chunks.
-- Equivalents of the 'Network.Wai.responseBuilder' family of functions are
-- provided for creating 'Responder's conveniently.
--
-- Pushed streams are handled by an IO action that triggers a server push.  It
-- returns @True@ if the @PUSH_PROMISE@ frame was sent, @False@ if not.  Note
-- this means it will still return @True@ if the client reset or ignored the
-- stream.  This gives handlers the freedom to implement their own heuristics
-- for whether to actually push a resource, while also allowing middleware and
-- frameworks to trigger server pushes automatically.

module Network.Wai.HTTP2
    (
    -- * Applications
      HTTP2Application
    -- * Responder
    , Responder
    , Body
    , BodyOf
    , Chunk(..)
    , Trailers
    -- * Server push
    , PushFunc
    , PushPromise(..)
    , promiseHeaders
    -- * Conveniences
    , promoteApplication
    -- ** Responders
    , responder
    , respondFile
    , respondFilePart
    , respondNotFound
    -- ** Stream Bodies
    , SimpleBody
    , streamFilePart
    , streamBuilder
    , streamSimple
    ) where

#if __GLASGOW_HASKELL__ < 710
import           Data.Functor ((<$))
#endif
import           Blaze.ByteString.Builder (Builder)
import           Data.ByteString (ByteString)
import qualified Network.HTTP.Types as H

import           Network.Wai (Application)
import           Network.Wai.Internal
    ( FilePart(..)
    , Request(requestHeaders)
    , Response(..)
    , ResponseReceived(..)
    , adjustForFilePart
    , chooseFilePart
    , tryGetFileSize
    )

-- | Headers sent after the end of a data stream, as defined by section 4.1.2 of
-- the HTTP\/1.1 spec (RFC 7230), and section 8.1 of the HTTP\/2 spec.
type Trailers = [H.Header]

-- | The synthesized request and headers of a pushed stream.
data PushPromise = PushPromise
    { promisedMethod :: H.Method
    , promisedPath :: ByteString
    , promisedAuthority :: ByteString
    , promisedScheme :: ByteString
    , promisedHeader :: H.RequestHeaders
    }

-- | The HTTP\/2-aware equivalent of 'Network.Wai.Application'.
type HTTP2Application = Request -> PushFunc -> Responder

-- | Part of a streaming response -- either a 'Builder' or a range of a file.
data Chunk = FileChunk FilePath FilePart | BuilderChunk Builder

-- | The streaming body of a response.  Equivalent to
-- 'Network.Wai.StreamingBody' except that it can also write file ranges and
-- return a result of type @a@.
type Body a = BodyOf Chunk a

-- | Generalization of 'Body' to arbitrary chunk types.
--
-- 'Network.Wai.StreamingBody' is identical to @BodyOf Builder ()@.
type BodyOf c a = (c -> IO ()) -> IO () -> IO a

-- | The result of an 'HTTP2Application'; or, alternately, an application
-- that's independent of the request.  This is a continuation-passing style
-- function that first provides a response by calling the given respond
-- function, then returns the request's 'Trailers'.
--
-- The respond function is similar to the one in 'Network.Wai.Application', but
-- it only takes a streaming body, the status and headers are curried, and it
-- passes on any result value from the stream body.
type Responder = (forall a. H.Status -> H.ResponseHeaders -> Body a -> IO a)
              -> IO Trailers

-- | A function given to an 'HTTP2Application' to initiate a server-pushed
-- stream.  Its argument is the same as the result of an 'HTTP2Application', so
-- you can either implement the response inline, or call your own application
-- to create the response.
type PushFunc = PushPromise -> Responder -> IO Bool

-- | Create the 'H.RequestHeaders' corresponding to the given 'PushPromise'.
--
-- This is primarily useful for Wai handlers like Warp, and application
-- implementers are unlikely to need it.
promiseHeaders :: PushPromise -> H.RequestHeaders
promiseHeaders p =
  [ (":method", promisedMethod p)
  , (":path", promisedPath p)
  , (":authority", promisedAuthority p)
  , (":scheme", promisedScheme p)
  ] ++ promisedHeader p

-- | Create a response body consisting of a single range of a file.  Does not
-- set Content-Length or Content-Range headers.  For that, use
-- 'respondFilePart' or 'respondFile'.
streamFilePart :: FilePath -> FilePart -> Body ()
streamFilePart path part write _ = write $ FileChunk path part

-- | Respond with a single range of a file, adding the Content-Length and
-- Content-Range headers and changing the status to 206 as appropriate.
--
-- If you want the range to be inferred automatically from the Range header,
-- use 'respondFile' instead.
respondFilePart :: H.Status -> H.ResponseHeaders -> FilePath -> FilePart -> Responder
respondFilePart s h path part respond = do
    let (s', h') = adjustForFilePart s h part
    respond s' h' $ streamFilePart path part
    return []

-- | Serve the requested range of the specified file (based on the Range
-- header), using the given 'H.Status' and 'H.ResponseHeaders' as a base.  If
-- the file is not accessible, the status will be replaced with 404 and a
-- default not-found message will be served.  If a partial file is requested,
-- the status will be replaced with 206 and the Content-Range header will be
-- added.  The Content-Length header will always be added.
respondFile :: H.Status -> H.ResponseHeaders -> FilePath -> H.RequestHeaders -> Responder
respondFile s h path req respond = do
    fileSize <- tryGetFileSize path
    case fileSize of
        Left _ -> respondNotFound h respond
        Right size -> respondFileExists s h path size req respond

-- As 'respondFile', but with prior knowledge of the file's existence and size.
respondFileExists :: H.Status -> H.ResponseHeaders -> FilePath -> Integer -> H.RequestHeaders -> Responder
respondFileExists s h path size reqHdrs =
    respondFilePart s h path $ chooseFilePart size $ lookup H.hRange reqHdrs

-- | Respond with a minimal 404 page with the given headers.
respondNotFound :: H.ResponseHeaders -> Responder
respondNotFound h respond = do
    respond H.notFound404 h' $ streamBuilder "File not found."
    return []
  where
    contentType = (H.hContentType, "text/plain; charset=utf-8")
    h' = contentType:filter ((/=H.hContentType) . fst) h

-- | Create a response body consisting of a single builder.
streamBuilder :: Builder -> Body ()
streamBuilder builder write _ = write $ BuilderChunk builder

-- | Equivalent to 'Body' but only streaming 'Builder's.
--
-- 'Network.Wai.StreamingBody' is identical to @SimpleBody ()@.
type SimpleBody a = BodyOf Builder a

-- | Create a response body of a stream of 'Builder's.
streamSimple :: SimpleBody a -> Body a
streamSimple body write flush = body (write . BuilderChunk) flush

-- | Use a normal WAI 'Response' to send the response.  Useful if you're
-- sharing code between HTTP\/2 applications and HTTP\/1 applications.
--
-- The 'Request' is used to determine the right file range to serve for
-- 'ResponseFile'.
responder :: Request -> Response -> Responder
responder req response respond = case response of
    (ResponseBuilder s h b)      -> [] <$ respond s h (streamBuilder b)
    (ResponseStream s h body)    -> [] <$ respond s h (streamSimple body)
    (ResponseRaw _ fallback)     -> responder req fallback respond
    (ResponseFile s h path mpart) -> go respond
      where
        -- Hooray, forcing things to be universally quantified.
        go :: Responder
        go = maybe
            (respondFile s h path $ requestHeaders req)
            (respondFilePart s h path)
            mpart

-- | Promote a normal WAI 'Application' to an 'HTTP2Application' by ignoring
-- the HTTP/2-specific features.
promoteApplication :: Application -> HTTP2Application
promoteApplication app req _ respond = [] <$ app req respond'
  where respond' r = ResponseReceived <$ responder req r respond