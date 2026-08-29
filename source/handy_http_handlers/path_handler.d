/**
 * Defines a path-matching request handler, that will match incoming requests
 * against a set of mappings based on the URL and HTTP method, and call a
 * handler depending on what's matched.
 */
module handy_http_handlers.path_handler;

import handy_http_primitives;
import path_matcher;
import slf4d;

/**
 * The key used to read and write path-handler related data to the request's
 * context data attribute.
 */
private immutable REQUEST_CONTEXT_DATA_KEY = "pathHandler";

/// Internal struct holding details about a handler mapping.
private struct HandlerMapping {
    /// The handler that will handle requests that match this mapping.
    HttpRequestHandler handler;
    /// A bitmask with bits enabled for the HTTP methods that this mapping matches to.
    immutable ushort methodsMask;
    /// A list of string patterns that this mapping matches to.
    immutable(string[]) patterns;
}

/// Maps each HTTP method to a bit value, so we can use bit-masking for handler mappings.
ushort getMethodBit(in string method) {
    if (method == HttpMethod.GET) return 1;
    if (method == HttpMethod.HEAD) return 2;
    if (method == HttpMethod.POST) return 4;
    if (method == HttpMethod.PUT) return 8;
    if (method == HttpMethod.DELETE) return 16;
    if (method == HttpMethod.CONNECT) return 32;
    if (method == HttpMethod.OPTIONS) return 64;
    if (method == HttpMethod.TRACE) return 128;
    if (method == HttpMethod.PATCH) return 256;
    throw new Exception("Unknown HTTP method: " ~ method);
}

/**
 * Computes a bitmask from a list of HTTP methods.
 * Params:
 *   methods = The methods to make a bitmask from.
 * Returns: A bitmask that matches all the given methods.
 */
ushort methodMaskFromMethods(HttpMethod[] methods) {
    ushort mask = 0;
    foreach (method; methods) {
        mask |= getMethodBit(method);
    }
    return mask;
}

/**
 * Gets a bitmask that matches all HTTP methods.
 * Returns: The bitmask.
 */
ushort methodMaskFromAll() {
    return ushort.max;
}

/**
 * Context data that may be attached to a request to provide additional data
 * from path matching results, like any path variables that were found.
 */
class PathHandlerContextData {
    immutable PathParam[] params;
    this(immutable(PathParam[]) params){
        this.params = params;
    }
}

/**
 * Gets the set of path variables that were matched when the given request was
 * handled by the path handler.
 * Params:
 *   request = The request to get path variables for.
 * Returns: The list of path variables.
 */
immutable(PathParam[]) getPathParams(in ServerHttpRequest request) {
    if (REQUEST_CONTEXT_DATA_KEY in request.contextData) {
        return (cast(PathHandlerContextData) request.contextData[REQUEST_CONTEXT_DATA_KEY]).params;
    }
    return [];
}

/**
 * Gets a specific path variable's value.
 * Params:
 *   request = The request to get the path variable value from.
 *   name = The name of the path variable.
 *   defaultValue = The default value to use if no path variables are present.
 * Returns: The path variable's value.
 */
T getPathParamAs(T)(in ServerHttpRequest request, string name, T defaultValue = T.init) {
    foreach (p; getPathParams(request)) {
        if (p.name == name) {
            return p.getAs!T;
        }
    }
    return defaultValue;
}

/**
 * Gets the specified path parameter as the given type T, or throws a NOT FOUND
 * status exception otherwise.
 * Params:
 *   request = The request to get the path variable from.
 *   name = The name of the path variable.
 * Returns: The path variable that was found.
 */
T getPathParamOrThrow(T)(in ServerHttpRequest request, string name) {
    import std.conv : ConvException;
    foreach (p; getPathParams(request)) {
        if (p.name == name) {
            try {
                return p.getAs!T;
            } catch (ConvException e) {
                // Skip and throw at the end if no params match.
            }
        }
    }
    throw new HttpStatusException(
        HttpStatus.NOT_FOUND,
        "Missing required path parameter \"" ~ name ~ "\"."
    );
}

/**
 * A request handler that maps incoming requests to a particular handler based
 * on the request's URL path and/or HTTP method (GET, POST, etc.).
 *
 * Use the various overloaded versions of the `addMapping(...)` method to add
 * handlers to this path handler. When handling requests, this path handler
 * will look for matches deterministically in the order you add them. Therefore,
 * adding mappings with conflicting or duplicate paths will cause the first one
 * to always be called.
 *
 * Path patterns should be defined according to the rules from the path-matcher
 * library, found here: https://github.com/andrewlalis/path-matcher
 */
class PathHandler : HttpRequestHandler {
    /// The internal list of all mapped handlers.
    private HandlerMapping[] mappings;

    /// The handler to use when no mapping is found for a request.
    private HttpRequestHandler notFoundHandler;

    /**
     * Constructs a new path handler with initially no mappings, and a default
     * notFoundHandler that simply sets a 404 status.
     */
    this() {
        this.mappings = [];
        this.notFoundHandler = HttpRequestHandler.of((ref request, ref response) {
            response.status = HttpStatus.NOT_FOUND;
        });
    }

    /**
     * Adds a mapping to this handler, such that requests which match the given
     * method and pattern will be handed off to the given handler.
     *
     * Overloaded variations of this method are defined for your convenience,
     * which allow you to add a mapping for multiple HTTP methods and/or path
     * patterns.
     *
     * Params:
     *   method = The HTTP method to match against.
     *   pattern = The path pattern to match against. See https://github.com/andrewlalis/path-matcher
     *             for more details on the pattern's format.
     *   handler = The handler that will handle matching requests.
     * Returns: This path handler, for method chaining.
     */
    PathHandler addMapping(HttpMethod method, string pattern, HttpRequestHandler handler) {
        this.mappings ~= HandlerMapping(handler, getMethodBit(method), [pattern]);
        return this;
    }
    ///
    PathHandler addMapping(HttpMethod[] methods, string pattern, HttpRequestHandler handler) {
        this.mappings ~= HandlerMapping(handler, methodMaskFromMethods(methods), [pattern]);
        return this;
    }
    ///
    PathHandler addMapping(HttpMethod method, string[] patterns, HttpRequestHandler handler) {
        this.mappings ~= HandlerMapping(handler, getMethodBit(method), patterns.idup);
        return this;
    }
    ///
    PathHandler addMapping(HttpMethod[] methods, string[] patterns, HttpRequestHandler handler) {
        this.mappings ~= HandlerMapping(handler, methodMaskFromMethods(methods), patterns.idup);
        return this;
    }
    ///
    PathHandler addMapping(string pattern, HttpRequestHandler handler) {
        this.mappings ~= HandlerMapping(handler, methodMaskFromAll(), [pattern]);
        return this;
    }
    
    /**
     * Sets the handler that will be called for requests that don't match any
     * pre-configured mappings.
     * Params:
     *   handler = The handler to use.
     * Returns: This path handler, for method chaining.
     */
    PathHandler setNotFoundHandler(HttpRequestHandler handler) {
        if (handler is null) throw new Exception("Cannot set PathHandler's notFoundHandler to null.");
        this.notFoundHandler = handler;
        return this;
    }

    /**
     * Handles a request by looking for a mapped handler whose method and pattern
     * match the request's, and letting that handler handle the request. If no
     * match is found, the notFoundHandler will take care of it.
     * Params:
     *   request = The request.
     *   response = The response.
     */
    void handle(ref ServerHttpRequest request, ref ServerHttpResponse response) {
        HttpRequestHandler mappedHandler = findMappedHandler(request);
        if (mappedHandler !is null) {
            mappedHandler.handle(request, response);
        } else {
            notFoundHandler.handle(request, response);
        }
    }

    /**
     * Adds mappings to this path handler which correspond to functions defined
     * in the given symbol which have been annotated with the `@PathMapping`
     * attribute (or any simplified aliases like `@GetMapping`).
     */
    void registerHandlers(alias symbol)() {
        static assert(
            __traits(isModule, symbol),
            "PathHandler.registerHandlers can only be called with a module."
        );
        import std.conv: to;
        HttpRequestHandler handlerRef;
        PathMapping pathMapping;
        bool foundMappingAttribute;
        static foreach (i, mem; __traits(allMembers, symbol)) {
            static if (isValidHandlerRegistrationTarget!(__traits(getMember, symbol, mem))) {
                // The symbol is a valid handler function, so iterate over its
                // attributes to find a @PathMapping or similar, and if present,
                // register the handler.
                mixin("alias target" ~ i.to!string ~ " = __traits(getMember, symbol, mem);");
                foundMappingAttribute = true;
                static foreach (attr; __traits(getAttributes, mixin("target" ~ i.to!string))) {
                    // Check if the attribute is one of the possible "Mapping" struct types.
                    static if (is(typeof(attr) == PathMapping)) {
                        pathMapping = attr;
                    } else static if (is(typeof(attr) == GetMapping)) {
                        pathMapping = PathMapping(HttpMethod.GET, attr.pattern);
                    } else static if (is(typeof(attr) == PostMapping)) {
                        pathMapping = PathMapping(HttpMethod.POST, attr.pattern);
                    } else static if (is(typeof(attr) == PutMapping)) {
                        pathMapping = PathMapping(HttpMethod.PUT, attr.pattern);
                    } else static if (is(typeof(attr) == DeleteMapping)) {
                        pathMapping = PathMapping(HttpMethod.DELETE, attr.pattern);
                    } else static if (is(typeof(attr) == PatchMapping)) {
                        pathMapping = PathMapping(HttpMethod.PATCH, attr.pattern);
                    } else {
                        foundMappingAttribute = false;
                    }
                    if (foundMappingAttribute) {
                        debugF!"Registered handler: %s %s -> %s"(
                            pathMapping.method,
                            pathMapping.pattern,
                            __traits(fullyQualifiedName, mixin("target" ~ i.to!string))
                        );
                        handlerRef = HttpRequestHandler.of(mixin("&target" ~ i.to!string));
                        this.addMapping(pathMapping.method, pathMapping.pattern, handlerRef);
                    }
                }
            }
        }
    }

    /**
     * Finds the handler to use to handle a given request, using our list of
     * pre-configured mappings.
     * Params:
     *   request = The request to find a handler for.
     * Returns: The handler that matches the request, or null if none is found.
     */
    private HttpRequestHandler findMappedHandler(ref ServerHttpRequest request) {
        const ushort methodBit = getMethodBit(request.method);
        foreach (HandlerMapping mapping; mappings) {
            if ((mapping.methodsMask & methodBit) > 0) {
                foreach (string pattern; mapping.patterns) {
                    PathMatchResult result = matchPath(request.url, pattern);
                    if (result.matches) {
                        debugF!"Found matching handler for %s %s: %s via pattern \"%s\""(
                            request.method,
                            request.url,
                            mapping.handler,
                            pattern
                        );
                        request.contextData[REQUEST_CONTEXT_DATA_KEY] = new PathHandlerContextData(result.pathParams);
                        return mapping.handler;
                    }
                }
            }
        }
        debugF!("No handler found for %s %s.")(request.method, request.url);
        return null;
    }
}

/**
 * A user-defined attribute that, when added to a function, allows that
 * function to be registered automatically by a path handler when you call
 * its `registerHandlers` method on the module containing the function.
 */
struct PathMapping {
    /**
     * The HTTP method that the mapping accepts.
     */
    HttpMethod method;
    /**
     * The path pattern for the mapping.
     */
    string pattern;
}

/**
 * A simplified version of `PathMapping` for HTTP GET mappings only.
 */
struct GetMapping {
    /**
     * See `PathMapping.pattern`.
     */
    string pattern;
}

/**
 * A simplified version of `PathMapping` for HTTP POST mappings only.
 */
struct PostMapping {
    /**
     * See `PathMapping.pattern`.
     */
    string pattern;
}

/**
 * A simplified version of `PathMapping` for HTTP PUT mappings only.
 */
struct PutMapping {
    /**
     * See `PathMapping.pattern`.
     */
    string pattern;
}

/**
 * A simplified version of `PathMapping` for HTTP DELETE mappings only.
 */
struct DeleteMapping {
    /**
     * See `PathMapping.pattern`.
     */
    string pattern;
}

/**
 * A simplified version of `PathMapping` for HTTP PATCH mappings only.
 */
struct PatchMapping {
    /**
     * See `PathMapping.pattern`.
     */
    string pattern;
}

/**
 * Determines if a symbol refers to a function that can be used as a request
 * handler at compile time.
 * Returns: True if the symbol refers to a valid request handler function.
 */
private bool isValidHandlerRegistrationTarget(alias symbol)() {
    import std.traits;
    static if (isFunction!(symbol)) {
        alias params = Parameters!(symbol);
        static if (params.length == 2) {
            alias paramStorageClasses = ParameterStorageClassTuple!(symbol);
            return is(params[0] == ServerHttpRequest) && is(params[1] == ServerHttpResponse) &&
            paramStorageClasses[0] == ParameterStorageClass.ref_ &&
            paramStorageClasses[1] == ParameterStorageClass.ref_ &&
            is(ReturnType!(symbol) == void);
        } else {
            return false;
        }
    } else {
        return false;
    }
}

// Test PathHandler.setNotFoundHandler
unittest {
    import std.exception;
    auto handler = new PathHandler();
    assertThrown!Exception(handler.setNotFoundHandler(null));
    auto notFoundHandler = HttpRequestHandler.of((ref request, ref response) {
        response.status = HttpStatus.NOT_FOUND;
    });
    assertNotThrown!Exception(handler.setNotFoundHandler(notFoundHandler));
}

// Test PathHandler.handle
unittest {
    class SimpleOkHandler : HttpRequestHandler {
        void handle(ref ServerHttpRequest request, ref ServerHttpResponse response) {
            response.status = HttpStatus.OK;
        }
    }

    PathHandler handler = new PathHandler()
        .addMapping(HttpMethod.GET, "/home", new SimpleOkHandler())
        .addMapping(HttpMethod.GET, "/users", new SimpleOkHandler())
        .addMapping(HttpMethod.GET, "/users/:id:ulong", new SimpleOkHandler())
        .addMapping(HttpMethod.GET, "/api/*", new SimpleOkHandler())
        .addMapping(HttpMethod.POST, "/api/do-something", new SimpleOkHandler());

    struct RequestAndResponse {
        ServerHttpRequest request;
        ServerHttpResponse response;
    }

    RequestAndResponse generateHandledData(HttpMethod method, string url) {
        ServerHttpRequest request = ServerHttpRequestBuilder()
            .withMethod(method)
            .withUrl(url)
            .build();
        ServerHttpResponse response = ServerHttpResponseBuilder().build();
        handler.handle(request, response);
        return RequestAndResponse(request, response);
    }

    auto result1 = generateHandledData(HttpMethod.GET, "/home");
    assert(result1.response.status == HttpStatus.OK);
    auto result2 = generateHandledData(HttpMethod.GET, "/home-not-exists");
    assert(result2.response.status == HttpStatus.NOT_FOUND);
    auto result3 = generateHandledData(HttpMethod.GET, "/users");
    assert(result3.response.status == HttpStatus.OK);
    auto result4 = generateHandledData(HttpMethod.GET, "/users/34");
    assert(result4.response.status == HttpStatus.OK);
    assert(getPathParamAs!ulong(result4.request, "id") == 34);
    auto result5 = generateHandledData(HttpMethod.GET, "/api/test");
    assert(result5.response.status == HttpStatus.OK);
    auto result6 = generateHandledData(HttpMethod.GET, "/api/test/bleh");
    assert(result6.response.status == HttpStatus.NOT_FOUND);
    auto result7 = generateHandledData(HttpMethod.GET, "/api");
    assert(result7.response.status == HttpStatus.NOT_FOUND);
    auto result8 = generateHandledData(HttpMethod.GET, "/");
    assert(result8.response.status == HttpStatus.NOT_FOUND);
    auto result9 = generateHandledData(HttpMethod.POST, "/api/do-something");
    assert(result9.response.status == HttpStatus.OK);
}

// Test registerHandlers
unittest {
    import handy_http_handlers.path_handler_sample_module;

    class C {}

    PathHandler ph = new PathHandler();
    ph.registerHandlers!(handy_http_handlers.path_handler_sample_module);
    
    // Verify that the handlers defined in the module were actually added.
    ServerHttpRequest req1 = ServerHttpRequestBuilder()
        .withMethod("GET")
        .withUrl("/h1")
        .build();
    ServerHttpResponse resp1 = ServerHttpResponseBuilder().build();
    ph.handle(req1, resp1);
    assert(resp1.status == HttpStatus.OK);

    ServerHttpRequest req2 = ServerHttpRequestBuilder()
        .withMethod("POST")
        .withUrl("/h2")
        .build();
    ServerHttpResponse resp2 = ServerHttpResponseBuilder().build();
    ph.handle(req2, resp2);
    assert(resp2.status == HttpStatus.OK);

    ServerHttpRequest req3 = ServerHttpRequestBuilder()
        .withMethod("GET")
        .withUrl("/h3")
        .build();
    ServerHttpResponse resp3 = ServerHttpResponseBuilder().build();
    ph.handle(req3, resp3);
    assert(resp3.status == HttpStatus.OK);

    // Verify that other stuff returns a 404.
    ServerHttpRequest req4 = ServerHttpRequestBuilder()
        .withMethod("GET")
        .withUrl("/h2")
        .build();
    ServerHttpResponse resp4 = ServerHttpResponseBuilder().build();
    ph.handle(req4, resp4);
    assert(resp4.status == HttpStatus.NOT_FOUND);

}
