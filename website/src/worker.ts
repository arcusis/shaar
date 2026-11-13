// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

interface Environment {
  ASSETS: { fetch(request: Request): Promise<Response> };
}

export default {
  async fetch(request: Request, environment: Environment): Promise<Response> {
    const url = new URL(request.url);
    if (["/404", "/404/", "/404.html"].includes(url.pathname)) {
      url.pathname = "/404";
      const notFound = await environment.ASSETS.fetch(new Request(url, request));
      return new Response(notFound.body, {
        status: 404,
        statusText: "Not Found",
        headers: notFound.headers,
      });
    }
    return environment.ASSETS.fetch(request);
  },
};
