// Copyright (c) 2016, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/services/search/search_engine.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/dart/analysis/driver_based_analysis_context.dart';
import 'package:analyzer/src/dart/analysis/search.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/generated/source.dart' show Source, SourceRange;
import 'package:analyzer/src/util/performance/operation_performance.dart';

/// A [SearchEngine] implementation.
class SearchEngineImpl implements SearchEngine {
  final Iterable<AnalysisDriver> _drivers;

  SearchEngineImpl(this._drivers);

  @override
  Future<void> appendAllSubtypes(
      InterfaceElement type,
      Set<InterfaceElement> allSubtypes,
      OperationPerformanceImpl performance) async {
    var searchEngineCache = SearchEngineCache();

    Future<void> addSubtypes(InterfaceElement type) async {
      var directResults = await performance.runAsync(
          '_searchDirectSubtypes',
          (performance) =>
              _searchDirectSubtypes(type, searchEngineCache, performance));
      for (var directResult in directResults) {
        var directSubtype = directResult.enclosingElement as InterfaceElement;
        if (allSubtypes.add(directSubtype)) {
          await addSubtypes(directSubtype);
        }
      }
    }

    await addSubtypes(type);
  }

  @override
  Future<Set<String>?> membersOfSubtypes(InterfaceElement type) async {
    var drivers = _drivers.toList();
    var searchedFiles = _createSearchedFiles(drivers);

    var libraryUriStr = type.librarySource.uri.toString();
    var hasSubtypes = false;
    var visitedIds = <String>{};
    var members = <String>{};

    Future<void> addMembers(
        InterfaceElement? type, SubtypeResult? subtype) async {
      if (subtype != null && !visitedIds.add(subtype.id)) {
        return;
      }
      for (var driver in drivers) {
        var subtypes = await driver.search
            .subtypes(searchedFiles, type: type, subtype: subtype);
        for (var subtype in subtypes) {
          hasSubtypes = true;
          members.addAll(subtype.libraryUri == libraryUriStr
              ? subtype.members
              : subtype.members.where((name) => !name.startsWith('_')));
          await addMembers(null, subtype);
        }
      }
    }

    await addMembers(type, null);

    if (!hasSubtypes) {
      return null;
    }
    return members;
  }

  @override
  Future<List<SearchMatch>> searchMemberDeclarations(String name) async {
    var allDeclarations = <SearchMatch>[];
    var drivers = _drivers.toList();
    var searchedFiles = _createSearchedFiles(drivers);
    for (var driver in drivers) {
      var elements = await driver.search.classMembers(name, searchedFiles);
      allDeclarations.addAll(elements.map(SearchMatchImpl.forElement));
    }
    return allDeclarations;
  }

  @override
  Future<List<SearchMatch>> searchMemberReferences(String name) async {
    var allResults = <SearchResult>[];
    var drivers = _drivers.toList();
    var searchedFiles = _createSearchedFiles(drivers);
    for (var driver in drivers) {
      var results =
          await driver.search.unresolvedMemberReferences(name, searchedFiles);
      allResults.addAll(results);
    }
    return allResults.map(SearchMatchImpl.forSearchResult).toList();
  }

  @override
  Future<Set<String>> searchPrefixesUsedInLibrary(
      covariant LibraryElementImpl library, Element element) async {
    var driver =
        (library.session.analysisContext as DriverBasedAnalysisContext).driver;
    return await driver.search.prefixesUsedInLibrary(library, element);
  }

  @override
  Future<List<SearchMatch>> searchReferences(Element element) async {
    var allResults = <SearchResult>[];
    var drivers = _drivers.toList();
    var searchedFiles = _createSearchedFiles(drivers);
    for (var driver in drivers) {
      var results = await driver.search.references(element, searchedFiles);
      allResults.addAll(results);
    }
    return allResults.map(SearchMatchImpl.forSearchResult).toList();
  }

  @override
  Future<List<SearchMatch>> searchSubtypes(
      InterfaceElement type, SearchEngineCache searchEngineCache,
      {OperationPerformanceImpl? performance}) async {
    performance ??= OperationPerformanceImpl('<root>');
    var results =
        await _searchDirectSubtypes(type, searchEngineCache, performance);
    return results.map(SearchMatchImpl.forSearchResult).toList();
  }

  @override
  Future<List<SearchMatch>> searchTopLevelDeclarations(String pattern) async {
    var allElements = <Element>{};
    var regExp = RegExp(pattern);
    var drivers = _drivers.toList();
    for (var driver in drivers) {
      var elements = await driver.search.topLevelElements(regExp);
      allElements.addAll(elements);
    }
    return allElements.map(SearchMatchImpl.forElement).toList();
  }

  /// Create a new [SearchedFiles] instance in which added files are owned
  /// by the drivers that have them added.
  SearchedFiles _createSearchedFiles(List<AnalysisDriver> drivers) {
    var searchedFiles = SearchedFiles();
    for (var driver in drivers) {
      searchedFiles.ownAnalyzed(driver.search);
    }
    return searchedFiles;
  }

  Future<List<SearchResult>> _searchDirectSubtypes(
      InterfaceElement type,
      SearchEngineCache searchEngineCache,
      OperationPerformanceImpl performance) async {
    var allResults = <SearchResult>[];

    // Fill out cache if needed.
    var drivers = searchEngineCache.drivers ??= _drivers.toList();
    var searchedFiles =
        searchEngineCache.searchedFiles ??= _createSearchedFiles(drivers);
    var assignedFiles = searchEngineCache.assignedFiles;
    if (assignedFiles == null) {
      assignedFiles = searchEngineCache.assignedFiles = {};
      for (var driver in drivers) {
        var assignedFilesForDrive = assignedFiles[driver] = [];
        await performance.runAsync(
            'discoverAvailableFiles', (_) => driver.discoverAvailableFiles());
        for (var file in driver.fsState.knownFiles) {
          if (searchedFiles.add(file.path, driver.search)) {
            assignedFilesForDrive.add(file);
          }
        }
      }
    }

    for (var driver in drivers) {
      var results = await performance.runAsync(
          'subTypes',
          (_) => driver.search.subTypes(type, searchedFiles,
              filesToCheck: assignedFiles![driver]));
      allResults.addAll(results);
    }
    return allResults;
  }
}

class SearchMatchImpl implements SearchMatch {
  @override
  final String file;

  @override
  final Source librarySource;

  @override
  final Source unitSource;

  @override
  final LibraryElement libraryElement;

  @override
  final Element element;

  @override
  final bool isResolved;

  @override
  final bool isQualified;

  @override
  final MatchKind kind;

  @override
  final SourceRange sourceRange;

  SearchMatchImpl(
      this.file,
      this.librarySource,
      this.unitSource,
      this.libraryElement,
      this.element,
      this.isResolved,
      this.isQualified,
      this.kind,
      this.sourceRange);

  @override
  String toString() {
    var buffer = StringBuffer();
    buffer.write('SearchMatch(kind=');
    buffer.write(kind);
    buffer.write(', libraryUri=');
    buffer.write(librarySource.uri);
    buffer.write(', unitUri=');
    buffer.write(unitSource.uri);
    buffer.write(', range=');
    buffer.write(sourceRange);
    buffer.write(', isResolved=');
    buffer.write(isResolved);
    buffer.write(', isQualified=');
    buffer.write(isQualified);
    buffer.write(')');
    return buffer.toString();
  }

  static SearchMatchImpl forElement(Element element) {
    return SearchMatchImpl(
        element.source!.fullName,
        element.librarySource!,
        element.source!,
        element.library!,
        element,
        true,
        true,
        MatchKind.DECLARATION,
        SourceRange(element.nameOffset, element.nameLength));
  }

  static SearchMatchImpl forSearchResult(SearchResult result) {
    var enclosingElement = result.enclosingElement;
    return SearchMatchImpl(
        enclosingElement.source!.fullName,
        enclosingElement.librarySource!,
        enclosingElement.source!,
        enclosingElement.library!,
        enclosingElement,
        result.isResolved,
        result.isQualified,
        toMatchKind(result.kind),
        SourceRange(result.offset, result.length));
  }

  static MatchKind toMatchKind(SearchResultKind kind) {
    if (kind == SearchResultKind.READ) {
      return MatchKind.READ;
    }
    if (kind == SearchResultKind.READ_WRITE) {
      return MatchKind.READ_WRITE;
    }
    if (kind == SearchResultKind.WRITE) {
      return MatchKind.WRITE;
    }
    if (kind == SearchResultKind.INVOCATION) {
      return MatchKind.INVOCATION;
    }
    if (kind ==
        SearchResultKind.INVOCATION_BY_ENUM_CONSTANT_WITHOUT_ARGUMENTS) {
      return MatchKind.INVOCATION_BY_ENUM_CONSTANT_WITHOUT_ARGUMENTS;
    }
    if (kind == SearchResultKind.REFERENCE_BY_CONSTRUCTOR_TEAR_OFF) {
      return MatchKind.REFERENCE_BY_CONSTRUCTOR_TEAR_OFF;
    }
    if (kind == SearchResultKind.REFERENCE_IN_EXTENDS_CLAUSE) {
      return MatchKind.REFERENCE_IN_EXTENDS_CLAUSE;
    }
    if (kind == SearchResultKind.REFERENCE_IN_IMPLEMENTS_CLAUSE) {
      return MatchKind.REFERENCE_IN_IMPLEMENTS_CLAUSE;
    }
    if (kind == SearchResultKind.REFERENCE_IN_ON_CLAUSE) {
      return MatchKind.REFERENCE_IN_ON_CLAUSE;
    }
    if (kind == SearchResultKind.REFERENCE_IN_WITH_CLAUSE) {
      return MatchKind.REFERENCE_IN_WITH_CLAUSE;
    }
    return MatchKind.REFERENCE;
  }
}
