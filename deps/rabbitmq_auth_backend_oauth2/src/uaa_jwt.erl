%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2024 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.
%%
-module(uaa_jwt).

-export([add_signing_key/3,
         decode_and_verify/1,
         get_jwk/2,
         verify_signing_key/2]).

-export([client_id/1, sub/1, client_id/2, sub/2]).

-include("oauth2.hrl").
-include_lib("jose/include/jose_jwk.hrl").

-import(rabbit_data_coercion, [
    to_map/1]).
-import(oauth2_client, [
    format_ssl_options/1,
    format_oauth_provider_id/1,
    get_oauth_provider/2]).
-import(resource_server, [
    resolve_resource_server_from_audience/1]).
-import(oauth_provider, [
    add_signing_key/2, get_signing_key/2,
    get_internal_oauth_provider/1,
    replace_signing_keys/2]).

-type key_type() :: json | pem | map.

-spec add_signing_key(binary(), key_type(), binary() | map()) -> {ok, map()} | {error, term()}.
add_signing_key(KeyId, Type, Value) ->
    case verify_signing_key(Type, Value) of
        ok ->
            {ok, add_signing_key(KeyId, {Type, Value})};
        {error, _} = Err ->
            Err
    end.

-spec update_jwks_signing_keys(oauth_provider()) -> ok | {error, term()}.
update_jwks_signing_keys(#oauth_provider{id = Id, jwks_uri = JwksUrl,
        ssl_options = SslOptions}) ->
    rabbit_log:debug("Downloading signing keys from ~tp (TLS options: ~p)",
        [JwksUrl, format_ssl_options(SslOptions)]),
    case uaa_jwks:get(JwksUrl, SslOptions) of
        {ok, {_, _, JwksBody}} ->
            KeyList = maps:get(<<"keys">>,
                jose:decode(erlang:iolist_to_binary(JwksBody)), []),
            Keys = maps:from_list(lists:map(fun(Key) ->
                {maps:get(<<"kid">>, Key, undefined), {json, Key}} end, KeyList)),
            rabbit_log:debug("Downloaded ~p signing keys", [maps:size(Keys)]),
            case replace_signing_keys(Keys, Id) of
              {error, _} = Err -> Err;
              _ -> ok
            end;
        {error, _} = Err ->
            rabbit_log:error("Failed to download signing keys: ~tp", [Err]),
            Err
    end.

-spec decode_and_verify(binary()) -> {boolean(), resource_server(), map()} | {error, term()}.
decode_and_verify(Token) ->
    case resolve_resource_server(Token) of
        {error, _} = Err ->
            Err;
        {ResourceServer, InternalOAuthProvider} ->
            decode_and_verify(Token, ResourceServer, InternalOAuthProvider)
    end.

-spec decode_and_verify(binary(), resource_server(), internal_oauth_provider())
        -> {boolean(), resource_server(), map()} | {error, term()}.
decode_and_verify(Token, ResourceServer, InternalOAuthProvider) ->
    OAuthProviderId = InternalOAuthProvider#internal_oauth_provider.id,
    rabbit_log:debug("Decoding token for resource_server: ~p using oauth_provider_id: ~p",
        [ResourceServer#resource_server.id,
        format_oauth_provider_id(OAuthProviderId)]),
    Result = case uaa_jwt_jwt:get_key_id(Token) of
        undefined -> InternalOAuthProvider#internal_oauth_provider.default_key;
        {ok, KeyId0} -> KeyId0;
        {error, _} = Err -> Err
    end,
    case Result of
        {error, _} = Err2 ->
            Err2;
        KeyId ->
            case get_jwk(KeyId, InternalOAuthProvider) of
                {ok, JWK} ->
                    Algorithms = InternalOAuthProvider#internal_oauth_provider.algorithms,
                    rabbit_log:debug("Verifying signature using signing_key_id : '~tp' and algorithms: ~p",
                        [KeyId, Algorithms]),
                    case uaa_jwt_jwt:decode_and_verify(Algorithms, JWK, Token) of
                        {true, Payload} -> {true, ResourceServer, Payload};
                        {false, Payload} -> {false, ResourceServer, Payload}
                    end;
                {error, _} = Err3 ->
                    Err3
            end
    end.

resolve_resource_server(Token) ->
    case uaa_jwt_jwt:get_aud(Token) of
        {error, _} = Error ->
            Error;
        {ok, Audience} ->
            case resolve_resource_server_from_audience(Audience) of
                {error, _} = Error ->
                    Error;
                {ok, ResourceServer} ->
                    {ResourceServer, get_internal_oauth_provider(
                        ResourceServer#resource_server.id)}
            end
    end.

-spec get_jwk(binary(), internal_oauth_provider()) -> {ok, map()} | {error, term()}.
get_jwk(KeyId, InternalOAuthProvider) ->
    get_jwk(KeyId, InternalOAuthProvider, true).

get_jwk(KeyId, InternalOAuthProvider, AllowUpdateJwks) ->
    OAuthProviderId = InternalOAuthProvider#internal_oauth_provider.id,
    case get_signing_key(KeyId, OAuthProviderId) of
        undefined ->
            case AllowUpdateJwks of
                true ->
                    rabbit_log:debug("Signing key '~tp' not found. Downloading it... ", [KeyId]),
                    case get_oauth_provider(OAuthProviderId, [jwks_uri]) of
                        {ok, OAuthProvider} ->
                            case update_jwks_signing_keys(OAuthProvider) of
                                ok ->
                                    get_jwk(KeyId, InternalOAuthProvider, false);
                                {error, no_jwks_url} ->
                                    {error, key_not_found};
                                {error, _} = Err ->
                                    Err
                            end;
                        {error, _} = Error ->
                            rabbit_log:debug("Unable to download signing keys due to ~p", [Error]),
                            Error
                    end;
                false            ->
                    rabbit_log:debug("Signing key '~tp' not found. Downloading is not allowed", [KeyId]),
                    {error, key_not_found}
            end;
        {Type, Value} ->
            rabbit_log:debug("Signing key ~p found", [KeyId]),
            case Type of
                json     -> uaa_jwt_jwk:make_jwk(Value);
                pem      -> uaa_jwt_jwk:from_pem(Value);
                pem_file -> uaa_jwt_jwk:from_pem_file(Value);
                map      -> uaa_jwt_jwk:make_jwk(Value);
                _        -> {error, unknown_signing_key_type}
            end
    end.

verify_signing_key(Type, Value) ->
    Verified = case Type of
        json     -> uaa_jwt_jwk:make_jwk(Value);
        pem      -> uaa_jwt_jwk:from_pem(Value);
        pem_file -> uaa_jwt_jwk:from_pem_file(Value);
        map      -> uaa_jwt_jwk:make_jwk(Value);
        _         -> {error, unknown_signing_key_type}
    end,
    case Verified of
        {ok, Key} ->
            case jose_jwk:from(Key) of
                #jose_jwk{}     -> ok;
                {error, Reason} -> {error, Reason}
            end;
        Err -> Err
    end.


-spec client_id(map()) -> binary() | undefined.
client_id(DecodedToken) ->
    maps:get(<<"client_id">>, DecodedToken, undefined).

-spec client_id(map(), any()) -> binary() | undefined.
client_id(DecodedToken, Default) ->
    maps:get(<<"client_id">>, DecodedToken, Default).

-spec sub(map()) -> binary() | undefined.
sub(DecodedToken) ->
    maps:get(<<"sub">>, DecodedToken, undefined).

-spec sub(map(), any()) -> binary() | undefined.
sub(DecodedToken, Default) ->
    maps:get(<<"sub">>, DecodedToken, Default).
