# Access service third-party notices

These components are used by the service. They are not bundled in the Apple apps.

| Component                                                                                               | License and notices                                                                        |
| ------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| [Fastify Busboy 3.2.4](https://github.com/fastify/busboy/tree/v3.2.4), including Dicer and StreamSearch | MIT; [Busboy license](LICENSES/fastify-busboy.txt) and [Dicer license](LICENSES/dicer.txt) |
| [jsonc-parser 3.3.1](https://github.com/microsoft/node-jsonc-parser/tree/v3.3.1)                        | MIT; [license](LICENSES/jsonc-parser.txt)                                                  |
| [Bun 1.4.4](https://github.com/oven-sh/bun/tree/bun-v1.4.4), embedded in the private service executable | [Runtime and linked-library notices](LICENSES/Bun.md)                                      |

The executable is deployed privately. Public executable or container distribution
requires a separate review of the embedded runtime's LGPL source and relinking
obligations. Keep these notices and licenses with the service source.
