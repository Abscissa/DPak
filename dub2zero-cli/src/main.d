import std.algorithm.iteration;
import std.stdio;
import std.utf;

import scriptlike;
import stdx.data.json;
import vibe.inet.urltransfer : download;

//TODO: This tool should include and use its own copy of 0install, to avoid
//      relying on the user having it already set up.

/++
Current Requirements (What this tool relies on):
- opam
- 0install v2.12+ (obtained through opam)
- unzip (a standard Linux version of it)
- eval (Such as in bash)

Eventual goal is to minimize or eliminate these dependencies.
But for the moment, these are what this tool currently relies on.
+/

immutable appName = "dub2zero-cli";
immutable usage = "Usage: "~appName~" [--help] PACKAGE_NAME";

immutable feedTemplateRoot = `
<?xml version="1.0"?>
<interface xmlns="http://zero-install.sourceforge.net/2004/injector/interface"
  min-injector-version='2.12'
  uri='https://semitwist.com/dpak/packages/PACK_NAME'>

  <name>dub-PACK_NAME</name>
  <summary>PACK_SUMMARY</summary>

  <group>
    <command name="run" path="myprog"/>
PACK_IMPLS
  </group>
</interface>
`;

immutable feedTemplateImpls = `
    <implementation id="dpak-dub-PACK_NAME-PACK_VER" version="PACK_VER">
      <manifest-digest sha256new="PACK_ARCHIVE_SHA256"/>
      <archive extract="dpak-dub-PACK_NAME-PACK_VER" href="PACK_ARCHIVE_URL" size="PACK_ARCHIVE_SIZE"/>
    </implementation>
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

/// The information in `dub describe`, slightly-procPACK_VERessed so we
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
	DubPackageRepo repo; /// The package's version control repository
	
	string latestVersion;
	string[] versionNames; /// Seems to be in decreasing order
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
		pack.repo = DubPackageRepo.fromJsonInfo(info);

		// Server seems to send versions in increasing order.
		// Not sure whether that's guaranteed behavior, but if it is,
		// let's reverse it to get decreasing order.
		foreach_reverse(i; 0..info["versions"].length)
		{
			auto verInfoRoot = info["versions"][i];
			auto ver = verInfoRoot["version"].toString;
			yap("ver: ", ver);

			pack.versionNames ~= ver;
			pack.versions[ver] = DubPackageImpl.fromVerInfo(verInfoRoot, packageName, ver, pack.repo);
		}

		return pack;
	}
}

/// The package's version control repository.
struct DubPackageRepo
{
	string project; /// Typically the package's name, but not always.
	string owner;
	string kind; /// ATM, only "github" is supported.
	
	string urlBase;
	
	string archiveUrl(string ver)
	{
		enforce(ver[0] != '~', "Archive URLs not supported for branches, only tagged releases.");
		//TODO: Are version tags *always* of the form "v1.2.3"? Because if they're ever "1.2.3" then this might fail.
		return urlBase~"archive/v"~ver~".zip";
	}
	
	static DubPackageRepo fromJsonInfo(JSONValue info)
	{
		DubPackageRepo ret;
		ret.project = info["repository"]["project"].toString;
		ret.owner   = info["repository"]["owner"].toString;
		ret.kind    = info["repository"]["kind"].toString;
		enforce(ret.kind == "github", "Unknown repo type '"~ret.kind~"' found, only 'github' is currently supported.");
		
		ret.urlBase = "https://github.com/"~ret.owner~"/"~ret.project~"/";
		return ret;
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
	
	size_t archiveSize; /// In bytes
	string archiveSha256;

	//JSONValue packageJson;
	//JSONValue targetJson;

	static DubPackageImpl fromVerInfo(JSONValue verInfoRoot, string name, string ver, DubPackageRepo repo)
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

		if(ver[0] != '~')
		{
			auto basename = name~"-"~ver;
			download(repo.archiveUrl(ver), basename~".zip");
			ret.archiveSize = getSize(basename~".zip");
			
			tryRemovePath(basename);
			run("unzip -q "~basename~".zip");
			auto manifestInfo = runCollect("eval $(opam config env) && 0store manifest "~basename~" sha256new");
			//yap(manifestInfo);
			
			// Last line of manifestInfo looks like: "sha256new_TD7LPDAAPVOP2EXWHSBNZJOFXXKNY6SE4VOPJWNMZFERMQU6KIJQ"
			auto lastLine = manifestInfo.byCodeUnit.strip.retro.splitter('\n').front.retro;
			auto shaResult = lastLine.findSplitAfter("sha256new_")[1]; // Strip "sha256new_" prefix
			ret.archiveSha256 = shaResult.array;
		}

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
	yap(rootDubPackage.repo.urlBase);
	yap(rootDubPackage.repo.archiveUrl(latestVer));

	ZeroPackage rootZeroPackage;

	string feedImpls;
	foreach(ver; rootDubPackage.versionNames)
	if(ver[0] != '~')
		feedImpls ~= feedTemplateImpls.byCodeUnit.substitute(
			"PACK_NAME",           rootDubPackage.name,
			"PACK_VER",            ver,
			"PACK_ARCHIVE_URL",    rootDubPackage.repo.archiveUrl(ver),
			"PACK_ARCHIVE_SIZE",   text(rootDubPackage.versions[ver].archiveSize),
			"PACK_ARCHIVE_SHA256", rootDubPackage.versions[ver].archiveSha256,
		).array.to!string; // I have no idea why byCodeUnit is giving me dchar[]...
	
	yap(
		feedTemplateRoot.byCodeUnit.substitute(
			"PACK_NAME",        rootDubPackage.name,
			"PACK_SUMMARY",     rootDubPackage.versions[latestVer].desc,
			"PACK_IMPLS",       feedImpls,
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
