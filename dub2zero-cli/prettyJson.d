#!/usr/bin/env dub
/+ dub.sdl:
	name "prettyJson"
	dependency "std_data_json" version="~>0.18.3"
+/
import std.exception;
import std.file;
import std.stdio;
import stdx.data.json;

/// Pretty print a JSON file to stdout.
void main(string[] args)
{
	enforce(args.length == 2 && args[1] != "--help", "USAGE: prettyJson IN.json (output will be stdout)");
	auto inFileName = args[1];
	
	auto inputStr = cast(string)read(inFileName);
	auto root = inputStr.toJSONValue();
	
	writeln(root.toJSON);
}
