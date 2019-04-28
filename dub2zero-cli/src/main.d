import std.stdio;
import scriptlike;
import stdx.data.json;
import std.algorithm.iteration;
import vibe.inet.urltransfer : download;

immutable appName = "dub2zero-cli";
immutable usage = "Usage: "~appName~" [--help] PACKAGE_NAME";

immutable feedTemplate = `
<?xml version="1.0"?>
<interface xmlns="http://zero-install.sourceforge.net/2004/injector/interface"
  min-injector-version='2.12'
  uri='PACK_URI'>

  <name>dub-PACK_NAME</name>
  <summary>PACK_SUMMARY</summary>

  <group>
    <command name="run" path="myprog"/>

    <implementation id="dpak-dub-PACK_NAME-PACK_VER" version="PACK_VER">
      <manifest-digest sha256new="FBXDJXLMHAPCRNZ5XOQTVYQHD6VP7CZAZ2UKCCV5UYE27C752GIQ"/>
      <archive extract="dub-PACK_NAME-PACK_VER" href="http://example.com/downloads/PACK_NAME-PACK_VER.zip" size="352"/>
    </implementation>
  </group>
</interface>
`;

/// Stolen from Scriptlike. Module scriptlike.core needs fixed on compiler (ex: DMD 2.081):
/// ../../scriptlike/src/scriptlike/core.d(331,3): Error: undefined identifier stderr
template trace()
{
	void trace(string file = __FILE__, size_t line = __LINE__)()
	{
		stderr.writeln(file, "(", line, "): trace");
		stderr.flush();
	}
}

/// Copied here from Scriptlike in order to work around DMD 19825
/// by removing the 'lazy' from args.
//void yap(T...)(lazy T args)
void yap(T...)(T args)
{
	import std.stdio;
	
	if(scriptlikeEcho || scriptlikeDryRun)
	{
		if(scriptlikeCustomEcho)
			scriptlikeCustomEcho(text(args));
		else
		{
			writeln(args);
			stdout.flush();
		}
	}
}

/// The information in `dub describe`, slightly-processed so we
/// can lookup packages and targets by name.
///
/// Not sure whether I'm going to need this after all,
/// but hang onto it for now, just in case.
struct DubDescribeInfo
{
	JSONValue root;

	string rootPackageName;
	JSONValue[string] packages;
	JSONValue[string] targets;
	
	/// Includes the root package itself as the first element.
	string[] subPackageNames;

	static DubDescribeInfo fromRawJson(string jsonStr)
	{
		DubDescribeInfo ret;

		ret.root = jsonStr.toJSONValue;
		ret.rootPackageName = ret.root["rootPackage"].toString;
		ret.subPackageNames ~= ret.rootPackageName;

		auto subPackagePrefix = ret.rootPackageName ~ ":";
		
		// Read packages
		foreach(i; 0..ret.root["packages"].length)
		{
			auto currPack = ret.root["packages"][i];
			auto currPackName = currPack["name"].toString;
			ret.packages[currPackName] = currPack;
			
			// Is this a subpackage of the root package?
			if(currPackName.startsWith(subPackagePrefix))
				ret.subPackageNames ~= currPackName;

			// Debug info
			yap("--------");
			yap(ret.root["packages"][i]["name"]);
			yap(ret.root["packages"][i]["version"]);
			yap(ret.root["packages"][i]["description"]);
		}
		yap("===============");

		// Read targets
		foreach(i; 0..ret.root["targets"].length)
		{
			auto currTarget = ret.root["targets"][i];
			ret.targets[currTarget["rootPackage"].toString] = currTarget;

			// Debug info
			yap("++++++++");
			yap(ret.root["targets"][i]["rootPackage"]);
			yap(ret.root["targets"][i]["packages"]);
			yap(ret.root["targets"][i]["dependencies"]);
			yap(ret.root["targets"][i]["linkDependencies"]);
		}
		yap("++++++++");

		return ret;
	}
}

/// Abstraction of a single package available in dub via code.dlang.org.
struct DubPackage
{
	string name;
	JSONValue jsonInfo;
	string latestVersion;
	string[] versionNames; // Seems to be in decreasing order
	DubPackageImpl[string] versions;

	static DubPackage fromCodeDlangOrg(string packageName)
	{
		download("https://code.dlang.org/api/packages/"~packageName~"/info", "info.json");
		auto info = (cast(string)read("info.json")).toJSONValue;
		yap(`info["dateAdded"]; `, info["dateAdded"]);

		download("https://code.dlang.org/api/packages/"~packageName~"/latest", "latest.json");
		auto latest = (cast(string)read("latest.json")).toJSONValue.toString;

		DubPackage pack;
		pack.jsonInfo = info;
		pack.latestVersion = latest;
		pack.name = packageName;
		yap("pack.name: ", pack.name);

		foreach_reverse(i; 0..info["versions"].length)
		{
			auto verInfoRoot = info["versions"][i];
			auto ver = verInfoRoot["version"].toString;
			yap("ver: ", ver);

			pack.versionNames ~= ver;
			pack.versions[ver] = DubPackageImpl.fromVerInfo(verInfoRoot, packageName, ver);
		}

		return pack;
	}
}

/// Abstraction of a single version of a single package available in dub via code.dlang.org.
struct DubPackageImpl
{
	JSONValue json;

	string name;
	string ver;
	string desc;
	string dateStr;
	size_t numSubPackages;

	//JSONValue packageJson;
	//JSONValue targetJson;

	static DubPackageImpl fromVerInfo(JSONValue verInfoRoot, string name, string ver)
	{
		DubPackageImpl ret;
		ret.json = verInfoRoot;
		ret.name = name;
		ret.ver = ver;

		if("description" in verInfoRoot)
			ret.desc = verInfoRoot["description"].toString;

		ret.dateStr = verInfoRoot["date"].toString;

		if("subPackages" in verInfoRoot)
			ret.numSubPackages = verInfoRoot["subPackages"].length;
		else
			ret.numSubPackages = 0;

		return ret;
	}
}

/// A 0install "feed". A package that includes all versions.
struct ZeroPackage
{
	string name;
	string uri;

	ZeroPackageImpl[] versions; // In decreasing order
}

/// A 0install "implementation". Ie, an individual version of a package.
struct ZeroPackageImpl
{
	string name;
	string ver;
	string summary;
	string archiveUrl;
	string archiveSize;
	string archiveHash; // sha256new
}

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

	failEnforce(args.length == 2, usage);

	scriptlikeEcho = !quiet;
}

Path sandbox(string packName)
{
	auto origDir = getcwd();

	auto packDir = tempDir~appName~packName;
	mkdirRecurse(packDir);
	chdir(packDir);

	return origDir;
}

void main(string[] args)
{
	processArgs(args);
	auto packName = args[1];

	auto workDir = sandbox(packName);
	yap("In: ", getcwd);
	
	auto rootDubPackage = DubPackage.fromCodeDlangOrg(packName);
	yap(rootDubPackage.versionNames);
	auto latestVer = rootDubPackage.latestVersion;
	yap(rootDubPackage.versions[latestVer].name);
	yap(rootDubPackage.versions[latestVer].ver);
	yap(rootDubPackage.versions[latestVer].desc);
	yap(rootDubPackage.versions[latestVer].dateStr);
	yap(rootDubPackage.versions[latestVer].numSubPackages);

	ZeroPackage rootZeroPackage;

	yap(
		feedTemplate.substitute(
			"PACK_NAME",    rootDubPackage.name,
			"PACK_SUMMARY", rootDubPackage.versions[latestVer].desc,
			"PACK_VER",     rootDubPackage.versions[latestVer].ver,
			//"PACK_",  dubInfo.targets[rootDubPackage.name][""].toString,
		)
	);

	/+
	run("dub fetch --cache=local "~packName~" --version="~packVer);
	chdir(Path(packName~"-"~packVer)~packName);
	
	auto dubInfo = DubDescribeInfo.fromRawJson( runCollect("dub describe") );
	yap("dubInfo.rootPackageName: ", dubInfo.rootPackageName);
	yap("dubInfo.subPackageNames: ", dubInfo.subPackageNames);
	+/
}
