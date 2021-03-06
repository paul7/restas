;;;; special.lisp
;;;;
;;;; This file is part of the RESTAS library, released under Lisp-LGPL.
;;;; See file COPYING for details.
;;;;
;;;; Author: Moskvitin Andrey <archimag@gmail.com>

(in-package :restas)

(defparameter *default-host-redirect* nil)

(defvar *request-pool*)

(defparameter *acceptors* nil)

(defvar *route* nil)

(defvar *submodule* nil)

(defvar *bindings*)

(defvar *memotable* nil)

(defvar *catch-errors-p* t)

(defparameter *max-debugging-threads* 5
  "Maximum number of simultaneous active calls invoke-debuger")

(defvar *debugging-threads* nil
  "List debugged threads")

(defvar *debugging-threads-lock* (bt:make-lock "debugging threads lock")
  "A global lock to prevent two threads from modifying *debugging-threads* at
the same time")
