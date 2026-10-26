// Hardcoded module "node:https"
const http = require("node:http");
const { urlToHttpOptions } = require("internal/url");

const ArrayPrototypeShift = Array.prototype.shift;
const ObjectAssign = Object.assign;
const ArrayPrototypeUnshift = Array.prototype.unshift;

function request(...args) {
  let options: any = {};

  if (typeof args[0] === "string") {
    const urlStr = ArrayPrototypeShift.$call(args);
    options = urlToHttpOptions(new URL(urlStr));
  } else if (args[0] instanceof URL) {
    options = urlToHttpOptions(ArrayPrototypeShift.$call(args));
  }

  if (args[0] && typeof args[0] !== "function") {
    ObjectAssign.$call(null, options, ArrayPrototypeShift.$call(args));
  }

  options._defaultAgent = https.globalAgent;
  ArrayPrototypeUnshift.$call(args, options);

  return new (http.ClientRequest as any)(...args);
}

function get(input, options, cb) {
  const req = request(input, options, cb);
  req.end();
  return req;
}

type AgentCtor = new (options?: any) => any;

function Agent(this: any, options?) {
  if (!(this instanceof Agent)) return new (Agent as unknown as AgentCtor)(options);

  const self: any = this;
  http.Agent.$apply(self, [options]);
  self.defaultPort = 443;
  self.protocol = "https:";
  self.maxCachedSessions = self.options.maxCachedSessions;
  if (self.maxCachedSessions === undefined) self.maxCachedSessions = 100;
}
$toClass(Agent, "Agent", http.Agent);

var https = {
  Agent,
  globalAgent: new (Agent as unknown as AgentCtor)({ keepAlive: true, scheduling: "lifo", timeout: 5000 }),
  Server: http.Server,
  createServer: http.createServer,
  get,
  request,
};
export default https;
