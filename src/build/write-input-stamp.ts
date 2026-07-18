await Bun.write(process.argv[2], "static_assert(sizeof(void*) > 0);\n");
