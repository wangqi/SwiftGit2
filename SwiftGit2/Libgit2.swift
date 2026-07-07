//
//  Libgit2.swift
//  SwiftGit2
//
//  Created by Matt Diephouse on 1/11/15.
//  Copyright (c) 2015 GitHub, Inc. All rights reserved.
//

import Clibgit2

/// One-time global libgit2 initialization. The ObjC +load constructor (SwiftGit2.m) is
/// excluded from the SPM build, so package consumers must call this once before any git
/// operation. Safe to call multiple times (libgit2 reference-counts). // wangqi modified 2026-07-07
public func initializeSwiftGit2() {
	git_libgit2_init()
}

extension git_strarray {
	func filter(_ isIncluded: (String) -> Bool) -> [String] {
		return map { $0 }.filter(isIncluded)
	}

	func map<T>(_ transform: (String) -> T) -> [T] {
		return (0..<self.count).map {
			let string = String(validatingUTF8: self.strings[$0]!)!
			return transform(string)
		}
	}
}
