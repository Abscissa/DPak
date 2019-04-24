import scriptlike;
import stdx.data.json;
import std.algorithm.iteration;

immutable appName = "dub2zero-cli";
immutable usage = "Usage: "~appName~" [--help] PACKAGE_NAME VERSION";

immutable feedTemplate = `
<?xml version="1.0"?>
<interface xmlns="http://zero-install.sourceforge.net/2004/injector/interface"
  min-injector-version='2.12'
  uri='PACK_URI'>

  <name>dub-PACK_NAME</name>
  <summary>PACK_DESC</summary>

  <group>
    <command name="run" path="myprog"/>

    <implementation id="dpak-dub-PACK_NAME-PACK_VER" version="PACK_VER">
      <manifest-digest sha256new="FBXDJXLMHAPCRNZ5XOQTVYQHD6VP7CZAZ2UKCCV5UYE27C752GIQ"/>
      <archive extract="dub-PACK_NAME-PACK_VER" href="http://example.com/downloads/PACK_NAME-PACK_VER.zip" size="352"/>
    </implementation>
  </group>
</interface>
`;

void processArgs(ref string[] args)
{
	bool quiet;
	auto cli = getopt(args,
		"quiet|q", &quiet
	);
	if(cli.helpWanted)
	{
		defaultGetoptPrinter(usage, cli.options);
		return;
	}

	failEnforce(args.length == 3, usage);

	scriptlikeEcho = !quiet;
}

Path sandbox(string packName, string packVer)
{
	auto origDir = getcwd();

	auto packDir = tempDir~appName~packName~packVer;
	mkdirRecurse(packDir);
	chdir(packDir);

	return origDir;
}

void main(string[] args)
{
	processArgs(args);
	auto packName = args[1];
	auto packVer  = args[2];

	auto workDir = sandbox(packName, packVer);
	yap("In: ", getcwd);
	
	run("dub fetch --cache=local "~packName~" --version="~packVer);
	chdir(Path(packName~"-"~packVer)~packName);
	
	auto dubJson = runCollect("dub describe").toJSONValue;
	auto rootPackageName = dubJson["rootPackage"];
	JSONValue[string] packages;
	foreach(i; 0..dubJson["packages"].length)
	{
		auto currPack = dubJson["packages"][i];
		packages[currPack["name"].toString] = currPack;

		yap("--------");
		yap(dubJson["packages"][i]["name"]);
		yap(dubJson["packages"][i]["version"]);
		yap(dubJson["packages"][i]["description"]);
	}
	yap("===============");
	JSONValue[string] targets;
	foreach(i; 0..dubJson["targets"].length)
	{
		auto currTarget = dubJson["targets"][i];
		targets[currPack["rootPackage"].toString] = currTarget;

		yap("++++++++");
		yap(dubJson["targets"][i]["rootPackage"]);
		yap(dubJson["targets"][i]["packages"]);
		yap(dubJson["targets"][i]["dependencies"]);
		yap(dubJson["targets"][i]["linkDependencies"]);
	}
	yap("++++++++");

	yap(
		feedTemplate.substitute(
			"PACK_NAME", rootPackageName,
			"PACK_DESC", packages[rootPackageName]["description"].toString,
			"PACK_VER",  packages[rootPackageName]["version"].toString,
			//"PACK_",  targets[rootPackageName][""].toString,
		)
	);
	run("echo ==================================================================");
	//run("cat dub.json");
}
