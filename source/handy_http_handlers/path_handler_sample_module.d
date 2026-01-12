/**
 * This module defines some path mapping functions to help test the path
 * handler's function for registering annotated functions.
 */
module handy_http_handlers.path_handler_sample_module;

version(unittest) {

import handy_http_primitives;
import handy_http_handlers.path_handler;

@PathMapping(HttpMethod.GET, "/h1")
void h1(ref ServerHttpRequest request, ref ServerHttpResponse response) {
    response.status = HttpStatus.OK;
}

@PathMapping(HttpMethod.POST, "/h2")
void h2(ref ServerHttpRequest request, ref ServerHttpResponse response) {
    response.status = HttpStatus.OK;
}

}