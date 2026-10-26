// Hardcoded module "node:crypto"
const StringDecoder = require("node:string_decoder").StringDecoder;
const LazyTransform = require("internal/streams/lazy_transform");
const { defineCustomPromisifyArgs } = require("internal/promisify");
const Writable = require("internal/streams/writable");
const { CryptoHasher } = Bun;

const {
  getCurves,
  certVerifySpkac,
  certExportPublicKey,
  certExportChallenge,
  getCiphers,
  getCipherInfo,
  Sign: _Sign,
  Verify: _Verify,
  Hmac: _Hmac,
  Hash: _Hash,
  ECDH,
  DiffieHellman,
  DiffieHellmanGroup,
  Cipher,
  publicEncrypt,
  publicDecrypt,
  privateEncrypt,
  privateDecrypt,

  KeyObject,

  createSecretKey,
  createPublicKey,
  createPrivateKey,

  X509Certificate,
} = {
  getCurves: $bindgenFn("node_crypto_binding.schema.zig", "getCurves"),
  certVerifySpkac: $bindgenFn("node_crypto_binding.schema.zig", "certVerifySpkac"),
  certExportPublicKey: $bindgenFn("node_crypto_binding.schema.zig", "certExportPublicKey"),
  certExportChallenge: $bindgenFn("node_crypto_binding.schema.zig", "certExportChallenge"),
  getCiphers: $bindgenFn("node_crypto_binding.schema.zig", "getCiphers"),
  getCipherInfo: $bindgenFn("node_crypto_binding.schema.zig", "getCipherInfo"),
  Sign: $bindgenClass("NodeCryptoSign.schema.zig", "Sign"),
  Verify: $bindgenClass("NodeCryptoSign.schema.zig", "Verify"),
  Hmac: $bindgenClass("NodeCryptoHmac.schema.zig", "Hmac"),
  Hash: $bindgenFn("node_crypto_binding.schema.zig", "hashConstructor")(),
  ECDH: $bindgenClass("NodeCryptoECDH.schema.zig", "ECDH"),
  DiffieHellman: $bindgenFn("node_crypto_binding.schema.zig", "diffieHellmanConstructor")(),
  DiffieHellmanGroup: $bindgenFn("node_crypto_binding.schema.zig", "diffieHellmanGroupConstructor")(),
  Cipher: $bindgenFn("node_crypto_binding.schema.zig", "cipherConstructor")(),
  publicEncrypt: $bindgenFn("node_crypto_binding.schema.zig", "publicEncrypt"),
  publicDecrypt: $bindgenFn("node_crypto_binding.schema.zig", "publicDecrypt"),
  privateEncrypt: $bindgenFn("node_crypto_binding.schema.zig", "privateEncrypt"),
  privateDecrypt: $bindgenFn("node_crypto_binding.schema.zig", "privateDecrypt"),
  KeyObject: $bindgenFn("node_crypto_binding.schema.zig", "keyObjectConstructor")(),
  createSecretKey: $bindgenFn("node_crypto_binding.schema.zig", "createSecretKey"),
  createPublicKey: $bindgenFn("node_crypto_binding.schema.zig", "createPublicKey"),
  createPrivateKey: $bindgenFn("node_crypto_binding.schema.zig", "createPrivateKey"),
  X509Certificate: $bindgenFn("node_crypto_binding.schema.zig", "x509CertificateConstructor")(),
};

const {
  pbkdf2: _pbkdf2,
  pbkdf2Sync,
  timingSafeEqual,
  randomInt: _randomInt,
  randomUUID,
  randomBytes: _randomBytes,
  randomBytesAsync: _randomBytesAsync,
  randomFillSync,
  randomFill: _randomFill,
  secureHeapUsed,
  getFips,
  setFips,
  setEngine,
  getHashes,
  scrypt: _scrypt,
  scryptSync,
  hkdf: _hkdf,
  hkdfSync,
  checkPrime: _checkPrime,
  checkPrimeSync,
  generatePrime: _generatePrime,
  generatePrimeSync: _generatePrimeSync,
  generateKey: _generateKey,
  generateKeySync: _generateKeySync,
  diffieHellman: _diffieHellman,
  diffieHellmanSync: _diffieHellmanSync,
  signOneShot: _signOneShot,
  signOneShotSync: _signOneShotSync,
  verifyOneShot: _verifyOneShot,
  verifyOneShotSync: _verifyOneShotSync,
  generateKeyPair: _generateKeyPair,
  generateKeyPairSync: _generateKeyPairSync,
} = {
  pbkdf2: $bindgenFn("node_crypto_binding.schema.zig", "pbkdf2"),
  pbkdf2Sync: $bindgenFn("node_crypto_binding.schema.zig", "pbkdf2Sync"),
  timingSafeEqual: $bindgenFn("node_crypto_binding.schema.zig", "timingSafeEqual"),
  randomInt: $bindgenFn("node_crypto_binding.schema.zig", "randomInt"),
  randomUUID: $bindgenFn("node_crypto_binding.schema.zig", "randomUUID"),
  randomBytes: $bindgenFn("node_crypto_binding.schema.zig", "randomBytes"),
  randomBytesAsync: $bindgenFn("node_crypto_binding.schema.zig", "randomBytesAsync"),
  randomFillSync: $bindgenFn("node_crypto_binding.schema.zig", "randomFillSync"),
  randomFill: $bindgenFn("node_crypto_binding.schema.zig", "randomFill"),
  secureHeapUsed: $bindgenFn("node_crypto_binding.schema.zig", "secureHeapUsed"),
  getFips: $bindgenFn("node_crypto_binding.schema.zig", "getFips"),
  setFips: $bindgenFn("node_crypto_binding.schema.zig", "setFips"),
  setEngine: $bindgenFn("node_crypto_binding.schema.zig", "setEngine"),
  getHashes: $bindgenFn("node_crypto_binding.schema.zig", "getHashes"),
  scrypt: $bindgenFn("node_crypto_binding.schema.zig", "scrypt"),
  scryptSync: $bindgenFn("node_crypto_binding.schema.zig", "scryptSync"),
  hkdf: $bindgenFn("node_crypto_binding.schema.zig", "hkdf"),
  hkdfSync: $bindgenFn("node_crypto_binding.schema.zig", "hkdfSync"),
  checkPrime: $bindgenFn("node_crypto_binding.schema.zig", "checkPrime"),
  checkPrimeSync: $bindgenFn("node_crypto_binding.schema.zig", "checkPrimeSync"),
  generatePrime: $bindgenFn("node_crypto_binding.schema.zig", "generatePrime"),
  generatePrimeSync: $bindgenFn("node_crypto_binding.schema.zig", "generatePrimeSync"),
  generateKey: $bindgenFn("node_crypto_binding.schema.zig", "generateKey"),
  generateKeySync: $bindgenFn("node_crypto_binding.schema.zig", "generateKeySync"),
  diffieHellman: $bindgenFn("node_crypto_binding.schema.zig", "diffieHellman"),
  diffieHellmanSync: $bindgenFn("node_crypto_binding.schema.zig", "diffieHellmanSync"),
  signOneShot: $bindgenFn("node_crypto_binding.schema.zig", "signOneShot"),
  signOneShotSync: $bindgenFn("node_crypto_binding.schema.zig", "signOneShotSync"),
  verifyOneShot: $bindgenFn("node_crypto_binding.schema.zig", "verifyOneShot"),
  verifyOneShotSync: $bindgenFn("node_crypto_binding.schema.zig", "verifyOneShotSync"),
  generateKeyPair: $bindgenFn("node_crypto_binding.schema.zig", "generateKeyPair"),
  generateKeyPairSync: $bindgenFn("node_crypto_binding.schema.zig", "generateKeyPairSync"),
};

const normalizeEncoding = $bindgenFn("NodeUtil.schema.zig", "normalizeEncoding");

const { validateString } = require("internal/validators");

const kHandle = Symbol("kHandle");

function verifySpkac(spkac, encoding) {
  return certVerifySpkac(getArrayBufferOrView(spkac, "spkac", encoding));
}
function exportPublicKey(spkac, encoding) {
  return certExportPublicKey(getArrayBufferOrView(spkac, "spkac", encoding));
}
function exportChallenge(spkac, encoding) {
  return certExportChallenge(getArrayBufferOrView(spkac, "spkac", encoding));
}

function Certificate(): void {
  if (!new.target) {
    return new Certificate();
  }

  this.verifySpkac = verifySpkac;
  this.exportPublicKey = exportPublicKey;
  this.exportChallenge = exportChallenge;
}
Certificate.prototype = {};
Certificate.verifySpkac = verifySpkac;
Certificate.exportPublicKey = exportPublicKey;
Certificate.exportChallenge = exportChallenge;

var Buffer = globalThis.Buffer;
const { isAnyArrayBuffer, isArrayBufferView } = require("node:util/types");

function getArrayBufferOrView(buffer, name, encoding?) {
  if (buffer instanceof KeyObject) {
    if (buffer.type !== "secret") {
      const error = new TypeError(
        `ERR_CRYPTO_INVALID_KEY_OBJECT_TYPE: Invalid key object type ${buffer.type}, expected secret`,
      );
      error.code = "ERR_CRYPTO_INVALID_KEY_OBJECT_TYPE";
      throw error;
    }
    buffer = buffer.export();
  }
  if (isAnyArrayBuffer(buffer)) return buffer;
  if (typeof buffer === "string") {
    if (encoding === "buffer") encoding = "utf8";
    return Buffer.from(buffer, encoding);
  }
  if (!isArrayBufferView(buffer)) {
    var error = new TypeError(
      `ERR_INVALID_ARG_TYPE: The "${name}" argument must be of type string or an instance of ArrayBuffer, Buffer, TypedArray, or DataView. Received ` +
        buffer,
    );
    error.code = "ERR_INVALID_ARG_TYPE";
    throw error;
  }
  return buffer;
}

const crypto = globalThis.crypto;

var crypto_exports: any = {};

crypto_exports.getRandomValues = value => crypto.getRandomValues(value);
crypto_exports.constants = $processBindingConstants.crypto;

crypto_exports.KeyObject = KeyObject;

crypto_exports.generateKey = generateKey;
crypto_exports.generateKeySync = generateKeySync;
defineCustomPromisifyArgs(generateKeyPair, ["publicKey", "privateKey"]);
crypto_exports.generateKeyPair = generateKeyPair;
crypto_exports.generateKeyPairSync = generateKeyPairSync;

crypto_exports.createSecretKey = createSecretKey;
crypto_exports.createPublicKey = createPublicKey;
crypto_exports.createPrivateKey = createPrivateKey;

var webcrypto = crypto;
var _subtle = webcrypto.subtle;

crypto_exports.hash = function hash(algorithm, input, outputEncoding: any = "hex") {
  return CryptoHasher.hash(algorithm, input, outputEncoding);
};

// TODO: move this to zig
function pbkdf2(password, salt, iterations, keylen, digest, callback) {
  if (typeof digest === "function") {
    callback = digest;
    digest = undefined;
  }

  const promise = _pbkdf2(password, salt, iterations, keylen, digest, callback);
  if (callback) {
    promise.then(
      result => callback(null, result),
      err => callback(err),
    );
    return;
  }

  promise.then(() => {});
}

function scrypt(password, salt, keylen, options, callback) {
  if (callback === undefined) {
    callback = options;
    options = undefined;
  }

  const promise = _scrypt(password, salt, keylen, options, callback);
  promise.then(
    result => callback(null, result),
    err => callback(err),
  );
}

function hkdf(digest, key, salt, info, length, callback) {
  _hkdf(digest, key, salt, info, length, callback).then(
    result => callback(null, result),
    err => callback(err),
  );
}

function checkPrime(candidate, options, callback) {
  if (typeof options === "function") {
    callback = options;
    options = undefined;
  }

  _checkPrime(candidate, options, callback).then(
    result => callback(null, result),
    err => callback(err),
  );
}

function materializeGeneratedPrime(result) {
  const { bytes, bigint } = result;
  if (bigint) {
    return BigInt(`0x${Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString("hex")}`);
  }

  if (bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength) {
    return bytes.buffer;
  }
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
}

function generatePrime(size, options, callback) {
  if (typeof options === "function") {
    callback = options;
    options = undefined;
  }

  _generatePrime(size, options, callback).then(
    result => callback(undefined, materializeGeneratedPrime(result)),
    err => callback(err),
  );
}

function generatePrimeSync(size, options) {
  return materializeGeneratedPrime(_generatePrimeSync(size, options));
}

function materializeGeneratedKey(bytes) {
  try {
    return createSecretKey(bytes);
  } finally {
    bytes.fill(0);
  }
}

function generateKey(type, options, callback) {
  _generateKey(type, options, callback).then(
    bytes => callback(null, materializeGeneratedKey(bytes)),
    err => callback(err),
  );
}

function generateKeySync(type, options) {
  return materializeGeneratedKey(_generateKeySync(type, options));
}

function generateKeyPair(type, options, callback) {
  if (typeof options === "function") {
    callback = options;
    options = undefined;
  }

  _generateKeyPair({ type, options }, callback).then(
    result => callback(null, result.publicKey, result.privateKey),
    err => callback(err),
  );
}

function generateKeyPairSync(type, options) {
  return _generateKeyPairSync({ type, options });
}

function diffieHellman(options, callback) {
  if (callback === undefined) {
    return _diffieHellmanSync(options);
  }

  _diffieHellman(options, callback).then(
    result => callback(null, result),
    err => callback(err),
  );
}

function sign(algorithm, data, key, callback) {
  if (callback === undefined) {
    return _signOneShotSync(algorithm, data, key);
  }

  _signOneShot(algorithm, data, key, callback).then(
    result => callback(null, result),
    err => callback(err),
  );
}

function verify(algorithm, data, key, signature, callback: any = undefined) {
  if (callback === undefined) {
    return _verifyOneShotSync(algorithm, data, key, signature);
  }

  _verifyOneShot(algorithm, data, key, signature, callback).then(
    result => callback(null, result),
    err => callback(err),
  );
}

function randomInt(min, max, callback = undefined) {
  if (typeof max === "function") {
    callback = max;
    max = min;
    min = 0;
  } else if (max === undefined) {
    max = min;
    min = 0;
  }

  const result = _randomInt(min, max, callback);
  if (callback !== undefined) {
    process.nextTick(callback, undefined, result);
    return;
  }
  return result;
}

function randomBytes(size, callback: any = undefined) {
  if (callback === undefined) return _randomBytes(size);

  _randomBytesAsync(size, callback).then(
    result => callback(null, result),
    err => callback(err),
  );
}

function randomFill(buffer, offset, size, callback) {
  if (typeof offset === "function") {
    callback = offset;
    offset = undefined;
    size = undefined;
  } else if (typeof size === "function") {
    callback = size;
    size = undefined;
  }

  _randomFill(buffer, offset, size, callback).then(
    () => {
      callback(null, buffer);
    },
    err => {
      callback(err);
    },
  );
}

crypto_exports.pbkdf2 = pbkdf2;
crypto_exports.pbkdf2Sync = pbkdf2Sync;

crypto_exports.hkdf = hkdf;
crypto_exports.hkdfSync = hkdfSync;

crypto_exports.getCurves = getCurves;
crypto_exports.getCipherInfo = getCipherInfo;
crypto_exports.timingSafeEqual = timingSafeEqual;
crypto_exports.webcrypto = webcrypto;
crypto_exports.subtle = _subtle;
crypto_exports.X509Certificate = X509Certificate;
crypto_exports.Certificate = Certificate;

function Sign(algorithm, options): void {
  if (!(this instanceof Sign)) {
    return new Sign(algorithm, options);
  }

  validateString(algorithm, "algorithm");
  this[kHandle] = new _Sign();
  this[kHandle].init(algorithm);

  Writable.$apply(this, [options]);
}
$toClass(Sign, "Sign", Writable);

Object.assign(Sign.prototype, {
  _write: function (chunk, encoding, callback) {
    this.update(chunk, encoding);
    callback();
  },
  update: function (data, encoding) {
    this[kHandle].update(data, encoding);
    return this;
  },
  sign: function (options, encoding) {
    return this[kHandle].sign(options, encoding);
  },
});

crypto_exports.Sign = Sign;
crypto_exports.sign = sign;

function createSign(algorithm, options?) {
  return new Sign(algorithm, options);
}

crypto_exports.createSign = createSign;

function Verify(algorithm, options): void {
  if (!(this instanceof Verify)) {
    return new Verify(algorithm, options);
  }

  validateString(algorithm, "algorithm");
  this[kHandle] = new _Verify();
  this[kHandle].init(algorithm);

  Writable.$apply(this, [options]);
}
$toClass(Verify, "Verify", Writable);

Verify.prototype._write = Sign.prototype._write;
Verify.prototype.update = Sign.prototype.update;

Object.assign(Verify.prototype, {
  verify: function (options, signature, sigEncoding) {
    return this[kHandle].verify(options, signature, sigEncoding);
  },
});

crypto_exports.Verify = Verify;
crypto_exports.verify = verify;

function createVerify(algorithm, options?) {
  return new Verify(algorithm, options);
}

crypto_exports.createVerify = createVerify;

function Hash(algorithm, options?): void {
  if (!new.target) {
    return new Hash(algorithm, options);
  }

  const handle = new _Hash(algorithm, options);
  this[kHandle] = handle;

  LazyTransform.$apply(this, [options]);
}
$toClass(Hash, "Hash", LazyTransform);

Object.assign(Hash.prototype, {
  copy: function (options) {
    return new Hash(this[kHandle], options);
  },
  _transform: function (chunk, encoding, callback) {
    this[kHandle].update(this, chunk, encoding);
    callback();
  },
  _flush: function (callback) {
    this.push(this[kHandle].digest(null, false));
    callback();
  },
  update: function (data, encoding) {
    return this[kHandle].update(this, data, encoding);
  },
  digest: function (outputEncoding) {
    return this[kHandle].digest(outputEncoding);
  },
});

crypto_exports.Hash = Hash;
crypto_exports.createHash = function createHash(algorithm, options) {
  return new Hash(algorithm, options);
};

function Hmac(hmac, key, options?): void {
  if (!new.target) {
    return new Hmac(hmac, key, options);
  }

  const handle = new _Hmac(hmac, key, options);
  this[kHandle] = handle;

  LazyTransform.$apply(this, [options]);
}
$toClass(Hmac, "Hmac", LazyTransform);

Object.assign(Hmac.prototype, {
  update: function (data, encoding) {
    this[kHandle].update(data, encoding);
    return this;
  },
  digest: function (outputEncoding) {
    return this[kHandle].digest(outputEncoding);
  },
  _transform: function (chunk, encoding, callback) {
    this[kHandle].update(chunk, encoding);
    callback();
  },
  _flush: function (callback) {
    this.push(this[kHandle].digest());
    callback();
  },
});

crypto_exports.Hmac = Hmac;
crypto_exports.createHmac = function createHmac(hmac, key, options) {
  return new Hmac(hmac, key, options);
};

crypto_exports.getHashes = getHashes;

crypto_exports.randomInt = randomInt;
crypto_exports.randomFill = randomFill;
crypto_exports.randomFillSync = randomFillSync;
crypto_exports.randomBytes = randomBytes;
crypto_exports.randomUUID = randomUUID;

crypto_exports.checkPrime = checkPrime;
crypto_exports.checkPrimeSync = checkPrimeSync;
crypto_exports.generatePrime = generatePrime;
crypto_exports.generatePrimeSync = generatePrimeSync;

crypto_exports.secureHeapUsed = secureHeapUsed;
crypto_exports.setEngine = setEngine;
crypto_exports.getFips = getFips;
crypto_exports.setFips = setFips;
Object.defineProperty(crypto_exports, "fips", {
  __proto__: null,
  get: getFips,
  set: setFips,
});

for (const rng of ["pseudoRandomBytes", "prng", "rng"]) {
  Object.defineProperty(crypto_exports, rng, {
    value: randomBytes,
    enumerable: false,
    configurable: true,
  });
}

function createDiffieHellman(sizeOrKey, keyEncoding, generator, genEncoding) {
  return new DiffieHellman(sizeOrKey, keyEncoding, generator, genEncoding);
}
crypto_exports.DiffieHellmanGroup = DiffieHellmanGroup;
crypto_exports.getDiffieHellman = crypto_exports.createDiffieHellmanGroup = DiffieHellmanGroup;
crypto_exports.createDiffieHellman = createDiffieHellman;
crypto_exports.DiffieHellman = DiffieHellman;

crypto_exports.diffieHellman = diffieHellman;

crypto_exports.ECDH = ECDH;
crypto_exports.createECDH = function createECDH(curve) {
  return new ECDH(curve);
};

{
  function getDecoder(decoder, encoding) {
    const normalizedEncoding = normalizeEncoding(encoding);
    decoder ||= new StringDecoder(encoding);
    if (decoder.encoding !== normalizedEncoding) {
      if (normalizedEncoding === undefined) {
        throw $ERR_UNKNOWN_ENCODING(encoding);
      }

      // there's a test for this
      // https://github.com/nodejs/node/blob/6b4255434226491449b7d925038008439e5586b2/lib/internal/crypto/cipher.js#L100
      // https://github.com/nodejs/node/blob/6b4255434226491449b7d925038008439e5586b2/test/parallel/test-crypto-encoding-validation-error.js#L31
      throw $ERR_INTERNAL_ASSERTION("Cannot change encoding");
    }
    return decoder;
  }

  function Cipheriv(cipher, key, iv, options): void {
    if (!new.target) {
      return new Cipheriv(cipher, key, iv, options);
    }

    this[kHandle] = new Cipher(false, cipher, key, iv, options);
    LazyTransform.$apply(this, [options]);
    this._decoder = null;
  }
  $toClass(Cipheriv, "Cipheriv", LazyTransform);

  Object.assign(Cipheriv.prototype, {
    setAutoPadding: function (ap) {
      this[kHandle].setAutoPadding(ap);
      return this;
    },
    getAuthTag: function () {
      return this[kHandle].getAuthTag();
    },
    setAAD: function (aadbuf, options) {
      this[kHandle].setAAD(aadbuf, options);
      return this;
    },
    _transform: function (chunk, encoding, callback) {
      this.push(this[kHandle].update(chunk, encoding));
      callback();
    },
    _flush: function (callback) {
      try {
        this.push(this[kHandle].final());
      } catch (e) {
        callback(e);
        return;
      }
      callback();
    },
    update: function (data, inputEncoding, outputEncoding) {
      const res = this[kHandle].update(data, inputEncoding);

      if (outputEncoding && outputEncoding !== "buffer") {
        this._decoder = getDecoder(this._decoder, outputEncoding);
        return this._decoder.write(res);
      }

      return res;
    },
    final: function (outputEncoding) {
      const res = this[kHandle].final();

      if (outputEncoding && outputEncoding !== "buffer") {
        this._decoder = getDecoder(this._decoder, outputEncoding);
        return this._decoder.end(res);
      }

      return res;
    },
  });

  function Decipheriv(cipher, key, iv, options): void {
    if (!new.target) {
      return new Decipheriv(cipher, key, iv, options);
    }

    this[kHandle] = new Cipher(true, cipher, key, iv, options);
    LazyTransform.$apply(this, [options]);
    this._decoder = null;
  }
  $toClass(Decipheriv, "Decipheriv", LazyTransform);

  Object.assign(Decipheriv.prototype, {
    setAutoPadding: Cipheriv.prototype.setAutoPadding,
    setAuthTag: function (tagbuf, encoding) {
      this[kHandle].setAuthTag(tagbuf, encoding);
      return this;
    },
    setAAD: Cipheriv.prototype.setAAD,
    _transform: Cipheriv.prototype._transform,
    _flush: Cipheriv.prototype._flush,
    update: Cipheriv.prototype.update,
    final: Cipheriv.prototype.final,
  });

  crypto_exports.Cipheriv = Cipheriv;
  crypto_exports.Decipheriv = Decipheriv;
  crypto_exports.createCipheriv = function createCipheriv(cipher, key, iv, options) {
    return new Cipheriv(cipher, key, iv, options);
  };
  crypto_exports.createDecipheriv = function createDecipheriv(cipher, key, iv, options) {
    return new Decipheriv(cipher, key, iv, options);
  };
  crypto_exports.getCiphers = getCiphers;
}

crypto_exports.scrypt = scrypt;
crypto_exports.scryptSync = scryptSync;

crypto_exports.publicEncrypt = publicEncrypt;
crypto_exports.publicDecrypt = publicDecrypt;
crypto_exports.privateEncrypt = privateEncrypt;
crypto_exports.privateDecrypt = privateDecrypt;

export default crypto_exports;
