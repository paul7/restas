;;;; route.lisp
;;;;
;;;; This file is part of the RESTAS library, released under Lisp-LGPL.
;;;; See file COPYING for details.
;;;;
;;;; Author: Moskvitin Andrey <archimag@gmail.com>


(in-package :restas)

(defgeneric process-route (route bindings))

(defclass route (routes:route)
  ((symbol :initarg :symbol :reader route-symbol)
   (submodule :initarg :submodule :initform nil)
   (required-method :initarg :required-method :initform nil :reader route-required-method)
   (arbitrary-requirement :initarg :arbitrary-requirement :initform nil :reader route-arbitrary-requirement)
   (render-method :initarg :render-method :initform #'identity)
   (headers :initarg :headers :initform nil :reader route-headers)))

(defun route-render-method (route)
  (or (slot-value route 'render-method)
      (string-symbol-value +render-method-symbol+
                           (slot-value (slot-value route
                                                   'submodule)
                                       'module))
      #'identity))

(defmethod routes:route-check-conditions ((route route) bindings)
  (let ((*route* route)
        (*submodule* (slot-value route 'submodule)))
    (with-context (slot-value *submodule* 'context)
      (with-slots (required-method arbitrary-requirement) route
        (and (if required-method
                 (eql (hunchentoot:request-method*) required-method)
                 t)
             (if arbitrary-requirement
                 (let ((*bindings* bindings))
                   (funcall arbitrary-requirement))
                 t))))))

(defmethod routes:route-name ((route route))
  (string-downcase (write-to-string (slot-value route 'symbol))))

(defmethod process-route ((route route) bindings)
  (alexandria:doplist (name value (route-headers route))
    (setf (hunchentoot:header-out name) value))
  (with-context (slot-value (slot-value route 'submodule) 'context)
    (let ((*route* route)
          (*bindings* bindings)
          (*submodule* (slot-value route 'submodule)))
    (render-object (route-render-method route)
                   (catch 'route-done
                     (funcall (slot-value route 'symbol)))))))

(defun abort-route-handler (obj &key return-code content-type)
  (when return-code
    (setf (hunchentoot:return-code*) return-code
          hunchentoot:*handle-http-errors-p* nil))
  (when content-type
    (setf (hunchentoot:content-type*) content-type))
  (throw 'route-done obj))

(defmacro define-route (name (template &key
                                       (method :get)
                                       content-type
                                       render-method
                                       requirement
                                       parse-vars
				       headers)
                        &body body)
  (let* ((variables (iter (for var in (routes:template-variables (routes:parse-template template)))
                          (collect (list (intern (symbol-name var))
                                         (list 'cdr (list 'assoc var '*bindings*)))))))
    `(progn
       (defun ,name (,@(if variables (cons '&key variables)))
         ,@body)
       (setf (symbol-plist ',name)
             (list :template ,template
                   :method ,method
                   :content-type ,content-type
                   :parse-vars ,parse-vars
                   :requirement ,requirement
                   :render-method ,render-method
		   :headers ,headers))
       (intern (symbol-name ',name)
               (symbol-value (find-symbol +routes-symbol+)))
       (export ',name)
       (eval-when (:execute)
         (reconnect-all-routes)))))

(defun route-template-from-symbol (symbol submodule)
  (concatenate 'list
               (submodule-full-baseurl submodule)
               (routes:parse-template (get symbol :template)
                                      (get symbol :parse-vars))))

(defun create-route-from-symbol (symbol submodule)
  (let* ((headers (append (string-symbol-value +headers-symbol+ 
					       (symbol-package symbol))
			  (get symbol :headers)))
	 (content-type (get symbol :content-type)))
    (cond
      (content-type 
       (setf (getf headers :content-type) content-type))
      ((not (getf headers :content-type))
       (setf (getf headers :content-type)
	     (or (string-symbol-value +content-type-symbol+
				      (symbol-package symbol))
		 "text/html"))))
	 (make-instance 'route
		   :template (route-template-from-symbol symbol submodule)
		   :symbol symbol
		   :required-method (get symbol :method)
		   :arbitrary-requirement (get symbol :requirement)
		   :render-method (get symbol :render-method)
		   :submodule submodule
		   :headers headers)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; generate url by route
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun route-symbol-template (route-symbol)
  (routes:parse-template (get route-symbol :template)))

(defun genurl/impl (tmpl args)
  (let ((uri (make-instance 'puri:uri)))
    (setf (puri:uri-parsed-path uri)
          (cons :absolute
                (routes::apply-bindings tmpl 
                                        (iter (for pair in (alexandria:plist-alist args))
                                              (collect (cons (car pair)
                                                             (if (or (stringp (cdr pair))
                                                                     (consp (cdr pair)))
                                                                 (cdr pair)
                                                                 (write-to-string (cdr pair)))))))))
    uri))


(defun genurl (route-symbol &rest args)
  (puri:render-uri (genurl/impl (concatenate 'list
                                             (submodule-full-baseurl *submodule*)
                                             (route-symbol-template route-symbol))
                                args)
                   nil))

(defun genurl-submodule (submodule-symbol route-symbol &rest args)
  (puri:render-uri (genurl/impl (concatenate 'list
                                             (submodule-full-baseurl (if submodule-symbol
                                                                         (find-submodule  submodule-symbol)
                                                                         *submodule*))
                                             (route-symbol-template route-symbol))
                                args)
                   nil))

(defun genurl-with-host (route &rest args)
  (let ((uri (genurl/impl (concatenate 'list
                                       (submodule-full-baseurl *submodule*)
                                       (route-symbol-template route))
                          args)))
    (setf (puri:uri-scheme uri)
          :http)
    (setf (puri:uri-host uri)
          (if (boundp 'hunchentoot:*request*)
                      (hunchentoot:host)
                      "localhost"))
    (puri:render-uri uri nil)))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; parse url for route
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(defun parse-route-url (url route-symbol &optional submodule-symbol)
  (let ((mapper (make-instance 'routes:mapper)))
    (routes:connect mapper
                    (make-instance 'routes:route
                                   :template (route-template-from-symbol route-symbol
                                                                         (if submodule-symbol
                                                                             (find-submodule  submodule-symbol)
                                                                             *submodule*))))
    (multiple-value-bind (route bindings) (routes:match mapper url)
      (if route
          (alexandria:alist-plist bindings)))))
  
