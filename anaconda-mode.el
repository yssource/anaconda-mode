;;; anaconda-mode.el --- Code navigation, documentation lookup and completion for Python  -*- lexical-binding: t; -*-

;; Copyright (C) 2013-2018 by Artem Malyshev

;; Author: Artem Malyshev <proofit404@gmail.com>
;; URL: https://github.com/proofit404/anaconda-mode
;; Version: 0.1.12
;; Package-Requires: ((emacs "25") (pythonic "0.1.0") (dash "2.6.0") (s "1.9") (f "0.16.2"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; See the README for more details.

;;; Code:

(require 'pythonic)
(require 'tramp)
(require 'xref)
(require 'json)
(require 'dash)
(require 'url)
(require 's)
(require 'f)

(defgroup anaconda-mode nil
  "Code navigation, documentation lookup and completion for Python."
  :group 'programming)

(defcustom anaconda-mode-installation-directory
  "~/.emacs.d/anaconda-mode"
  "Installation directory for `anaconda-mode' server."
  :group 'anaconda-mode
  :type 'directory)

(defcustom anaconda-mode-eldoc-as-single-line nil
  "If not nil, trim eldoc string to frame width."
  :group 'anaconda-mode
  :type 'boolean)

(defcustom anaconda-mode-lighter " Anaconda"
  "Text displayed in the mode line when `anaconda-mode’ is active."
  :group 'anaconda-mode
  :type 'sexp)


;;; Server.

(defvar anaconda-mode-server-version "0.1.12"
  "Server version needed to run `anaconda-mode'.")

(defvar anaconda-mode-server-command "
from __future__ import print_function

# CLI arguments.

import sys

assert len(sys.argv) > 3, 'CLI arguments: %s' % sys.argv

server_directory = sys.argv[-3]
server_address = sys.argv[-2]
virtual_environment = sys.argv[-1]

# Ensure directory.

import os

server_directory = os.path.expanduser(server_directory)

if not os.path.exists(server_directory):
    os.makedirs(server_directory)

# Installation check.

def instrument_installation():
    for path in os.listdir(server_directory):
        path = os.path.join(server_directory, path)
        if path.endswith('.egg') and os.path.isdir(path) and path not in sys.path:
            sys.path.insert(0, path)

missing_dependencies = []

instrument_installation()

try:
    import jedi
except ImportError:
    missing_dependencies.append('jedi>=0.12')

try:
    import service_factory
except ImportError:
    missing_dependencies.append('service_factory>=0.1.5')

# Installation.

if missing_dependencies:
    import site
    import setuptools.command.easy_install
    site.addsitedir(server_directory)
    setuptools.command.easy_install.main([
        '--install-dir', server_directory,
        '--site-dirs', server_directory,
        '--always-copy',
        '--always-unzip',
        *missing_dependencies
    ])
    instrument_installation()

# Setup server.

import jedi
import service_factory

assert jedi.__version__, 'Jedi version should be >= 0.12.0, current version: %s' % (
    jedi.__version__,
)

if virtual_environment:
    virtual_environment = jedi.create_environment(virtual_environment, safe=False)
else:
    virtual_environment = None

# Define JSON-RPC application.

import functools

def script_method(f):
    @functools.wraps(f)
    def wrapper(source, line, column, path):
        return f(jedi.Script(source, line, column, path, environment=virtual_environment))
    return wrapper

def process_definitions(f):
    @functools.wraps(f)
    def wrapper(script):
        return [[definition.module_path,
                 definition.line,
                 definition.column,
                 definition.get_line_code().strip()]
                for definition in f(script)]
    return wrapper

@script_method
def complete(script):
    return [[definition.name, definition.type]
            for definition in script.completions()]

@script_method
def company_complete(script):
    return [[definition.name,
             definition.type,
             definition.docstring(),
             definition.module_path,
             definition.line]
            for definition in script.completions()]

@script_method
def show_doc(script):
    return [[definition.module_name, definition.docstring()]
            for definition in script.goto_definitions()]

@script_method
@process_definitions
def goto_definitions(script):
    return script.goto_definitions()

@script_method
@process_definitions
def goto_assignments(script):
    return script.goto_assignments()

@script_method
@process_definitions
def usages(script):
    return script.usages()

@script_method
def eldoc(script):
    signatures = script.call_signatures()
    if len(signatures) == 1:
        signature = signatures[0]
        return [signature.name,
                signature.index,
                [param.description[6:] for param in signature.params]]

# Run.

app = [complete, company_complete, show_doc, goto_definitions, goto_assignments, usages, eldoc]

service_factory.service_factory(app, server_address, 0, 'anaconda_mode port {port}')
" "Run `anaconda-mode' server.")

(defvar anaconda-mode-process-name "anaconda-mode"
  "Process name for `anaconda-mode' processes.")

(defvar anaconda-mode-process-buffer "*anaconda-mode*"
  "Buffer name for `anaconda-mode' process.")

(defvar anaconda-mode-process nil
  "Currently running `anaconda-mode' process.")

(defvar anaconda-mode-port nil
  "Port for `anaconda-mode' connection.")

(defvar anaconda-mode-definition-commands
  '("complete" "goto_definitions" "goto_assignments" "usages")
  "List of `anaconda-mode' rpc commands returning definitions as result.

This is used to prefix `module-path' field with
`pythonic-tramp-connection' in the case of remote interpreter or
virtual environment.")

(defvar anaconda-mode-response-buffer "*anaconda-response*"
  "Buffer name for error report when `anaconda-mode' fail to read server response.")

(defvar anaconda-mode-socat-process-name "anaconda-socat"
  "Process name for `anaconda-mode' socat companion process.")

(defvar anaconda-mode-socat-process-buffer "*anaconda-socat*"
  "Buffer name for `anaconda-mode' socat companion process.")

(defvar anaconda-mode-socat-process nil
  "Currently running `anaconda-mode' socat companion process.")

(defvar anaconda-mode-ssh-process-name "anaconda-ssh"
  "Process name for `anaconda-mode' ssh port forward companion process.")

(defvar anaconda-mode-ssh-process-buffer "*anaconda-ssh*"
  "Buffer name for `anaconda-mode' ssh port forward companion process.")

(defvar anaconda-mode-ssh-process nil
  "Currently running `anaconda-mode' ssh port forward companion process.")

(defun anaconda-mode-server-directory ()
  "Anaconda mode installation directory."
  (f-short (f-join anaconda-mode-installation-directory
                   anaconda-mode-server-version)))

(defun anaconda-mode-host ()
  "Target host with `anaconda-mode' server."
  (cond
   ((pythonic-remote-docker-p)
    "127.0.0.1")
   ((pythonic-remote-p)
    (pythonic-remote-host))
   (t
    "127.0.0.1")))

(defun anaconda-mode-start (&optional callback)
  "Start `anaconda-mode' server.
CALLBACK function will be called when `anaconda-mode-port' will
be bound."
  (when (anaconda-mode-need-restart)
    (anaconda-mode-stop))
  (if (anaconda-mode-running-p)
      (and callback
           (anaconda-mode-bound-p)
           (funcall callback))
    (anaconda-mode-bootstrap callback)))

(defun anaconda-mode-stop ()
  "Stop `anaconda-mode' server."
  (when (anaconda-mode-running-p)
    (set-process-filter anaconda-mode-process nil)
    (set-process-sentinel anaconda-mode-process nil)
    (kill-process anaconda-mode-process)
    (setq anaconda-mode-process nil
          anaconda-mode-port nil))
  (when (anaconda-mode-socat-running-p)
    (kill-process anaconda-mode-socat-process)
    (setq anaconda-mode-socat-process nil))
  (when (anaconda-mode-ssh-running-p)
    (kill-process anaconda-mode-ssh-process)
    (setq anaconda-mode-ssh-process nil)))

(defun anaconda-mode-running-p ()
  "Is `anaconda-mode' server running."
  (and anaconda-mode-process
       (process-live-p anaconda-mode-process)))

(defun anaconda-mode-socat-running-p ()
  "Is `anaconda-mode' socat companion process running."
  (and anaconda-mode-socat-process
       (process-live-p anaconda-mode-socat-process)))

(defun anaconda-mode-ssh-running-p ()
  "Is `anaconda-mode' ssh port forward companion process running."
  (and anaconda-mode-ssh-process
       (process-live-p anaconda-mode-ssh-process)))

(defun anaconda-mode-bound-p ()
  "Is `anaconda-mode' port bound."
  (numberp anaconda-mode-port))

(defun anaconda-mode-need-restart ()
  "Check if we need to restart `anaconda-mode-server'."
  (when (and (anaconda-mode-running-p)
             (anaconda-mode-bound-p))
    (or (not (pythonic-proper-environment-p anaconda-mode-process))
        (not (equal (process-get anaconda-mode-process 'server-directory)
                    (anaconda-mode-server-directory))))))

(defun anaconda-mode-bootstrap (&optional callback)
  "Run `anaconda-mode' server.
CALLBACK function will be called when `anaconda-mode-port' will
be bound."
  (setq anaconda-mode-process
        (start-pythonic :process anaconda-mode-process-name
                        :buffer anaconda-mode-process-buffer
                        :filter (lambda (process output) (anaconda-mode-bootstrap-filter process output callback))
                        :query-on-exit nil
                        :args (list "-c"
                                    anaconda-mode-server-command
                                    (anaconda-mode-server-directory)
                                    (if (pythonic-remote-p) "0.0.0.0" "127.0.0.1")
                                    (or pythonic-environment ""))))
  (process-put anaconda-mode-process 'server-directory (anaconda-mode-server-directory)))

(defun anaconda-mode-bootstrap-filter (process output &optional callback)
  "Set `anaconda-mode-port' from PROCESS OUTPUT.
Connect to the `anaconda-mode' server.  CALLBACK function will be
called when `anaconda-mode-port' will be bound."
  ;; Mimic default filter.
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (save-excursion
        (goto-char (process-mark process))
        (insert output)
        (set-marker (process-mark process) (point)))))
  (--when-let (s-match "anaconda_mode port \\([0-9]+\\)" output)
    (setq anaconda-mode-port (string-to-number (cadr it)))
    (set-process-filter process nil)
    (cond ((pythonic-remote-docker-p)
           (let* ((container-raw-description (with-output-to-string
                                               (with-current-buffer
                                                   standard-output
                                                 (call-process "docker" nil t nil "inspect" (pythonic-remote-host)))))
                  (container-description (let ((json-array-type 'list))
                                           (json-read-from-string container-raw-description)))
                  (container-ip (cdr (assoc 'IPAddress
                                            (cdadr (assoc 'Networks
                                                          (cdr (assoc 'NetworkSettings
                                                                      (car container-description)))))))))
             (setq anaconda-mode-socat-process
                   (start-process anaconda-mode-socat-process-name
                                  anaconda-mode-socat-process-buffer
                                  "socat"
                                  (format "TCP4-LISTEN:%d" anaconda-mode-port)
                                  (format "TCP4:%s:%d" container-ip anaconda-mode-port)))
             (set-process-query-on-exit-flag anaconda-mode-socat-process nil)))
          ((pythonic-remote-vagrant-p)
           (setq anaconda-mode-ssh-process
                 (start-process anaconda-mode-ssh-process-name
                                anaconda-mode-ssh-process-buffer
                                "ssh" "-nNT"
                                (format "%s@%s" (pythonic-remote-user) (pythonic-remote-host))
                                "-p" (number-to-string (pythonic-remote-port))
                                "-L" (format "%s:%s:%s" anaconda-mode-port (pythonic-remote-host) anaconda-mode-port)))
           (set-process-query-on-exit-flag anaconda-mode-ssh-process nil)))
    (when callback
      (funcall callback))))


;;; Interaction.

(defun anaconda-mode-call (command callback)
  "Make remote procedure call for COMMAND.
Apply CALLBACK to it result."
  (anaconda-mode-start
   (lambda () (anaconda-mode-jsonrpc command callback))))

(defun anaconda-mode-jsonrpc (command callback)
  "Perform JSONRPC call for COMMAND.
Apply CALLBACK to the call result when retrieve it.  Remote
COMMAND must expect four arguments: python buffer content, line
number position, column number position and file path."
  (let ((url-request-method "POST")
        (url-request-data (anaconda-mode-jsonrpc-request command)))
    (url-retrieve
     (format "http://%s:%s" (anaconda-mode-host) anaconda-mode-port)
     (anaconda-mode-create-response-handler command callback)
     nil
     t)))

(defun anaconda-mode-jsonrpc-request (command)
  "Prepare JSON encoded buffer data for COMMAND call."
  (encode-coding-string (json-encode (anaconda-mode-jsonrpc-request-data command)) 'utf-8))

(defun anaconda-mode-jsonrpc-request-data (command)
  "Prepare buffer data for COMMAND call."
  `((jsonrpc . "2.0")
    (id . 1)
    (method . ,command)
    (params . ((source . ,(buffer-substring-no-properties (point-min) (point-max)))
               (line . ,(line-number-at-pos (point)))
               (column . ,(- (point) (line-beginning-position)))
               (path . ,(when (buffer-file-name)
                          (if (pythonic-remote-p)
                              (and
                               (tramp-tramp-file-p (buffer-file-name))
                               (equal (tramp-file-name-host
                                       (tramp-dissect-file-name
                                        (pythonic-tramp-connection)))
                                      (tramp-file-name-host
                                       (tramp-dissect-file-name
                                        (buffer-file-name))))
                               (pythonic-file-name (buffer-file-name)))
                            (buffer-file-name))))))))

(defun anaconda-mode-create-response-handler (command callback)
  "Create server response handler based on COMMAND and CALLBACK function.
COMMAND argument will be used for response skip message.
Response can be skipped if point was moved sense request was
submitted."
  (let ((anaconda-mode-request-point (point))
        (anaconda-mode-request-buffer (current-buffer))
        (anaconda-mode-request-window (selected-window))
        (anaconda-mode-request-tick (buffer-chars-modified-tick)))
    (lambda (status)
      (let ((http-buffer (current-buffer)))
        (unwind-protect
            (if (or (not (equal anaconda-mode-request-window (selected-window)))
                    (with-current-buffer (window-buffer anaconda-mode-request-window)
                      (or (not (equal anaconda-mode-request-buffer (current-buffer)))
                          (not (equal anaconda-mode-request-point (point)))
                          (not (equal anaconda-mode-request-tick (buffer-chars-modified-tick))))))
                nil
              (search-forward-regexp "\r?\n\r?\n" nil t)
              (let ((response (condition-case nil
                                  (json-read)
                                ((json-readtable-error json-end-of-file end-of-file)
                                 (let ((response (concat (format "# status: %s\n# point: %s\n" status (point))
                                                         (buffer-string))))
                                   (with-current-buffer (get-buffer-create anaconda-mode-response-buffer)
                                     (erase-buffer)
                                     (insert response)
                                     (goto-char (point-min)))
                                   nil)))))
                (if (null response)
                    (message "Cannot read anaconda-mode server response")
                  (if (assoc 'error response)
                      (let* ((error-structure (cdr (assoc 'error response)))
                             (error-message (cdr (assoc 'message error-structure)))
                             (error-data (cdr (assoc 'data error-structure)))
                             (error-template (if error-data "%s: %s" "%s")))
                        (apply 'message error-template (delq nil (list error-message error-data))))
                    (with-current-buffer anaconda-mode-request-buffer
                      (let ((result (cdr (assoc 'result response))))
                        (when (and (pythonic-remote-p)
                                   (member command anaconda-mode-definition-commands))
                          (setq result (--map (--map (let ((key (car it))
                                                           (value (cdr it)))
                                                       (when (and (eq key 'module-path) value)
                                                         (setq value (concat (pythonic-tramp-connection) value)))
                                                       (cons key value))
                                                     it)
                                              result)))
                        ;; Terminate `apply' call with empty list so response
                        ;; will be treated as single argument.
                        (apply callback result nil)))))))
          (kill-buffer http-buffer))))))


;;; Code completion.

(defun anaconda-mode-complete ()
  "Request completion candidates."
  (interactive)
  (unless (python-syntax-comment-or-string-p)
    (anaconda-mode-call "complete" 'anaconda-mode-complete-callback)))

(defun anaconda-mode-complete-callback (result)
  "Start interactive completion on RESULT receiving."
  (let* ((bounds (bounds-of-thing-at-point 'symbol))
         (start (or (car bounds) (point)))
         (stop (or (cdr bounds) (point)))
         (collection (anaconda-mode-complete-extract-names result))
         (completion-extra-properties '(:annotation-function anaconda-mode-complete-annotation)))
    (completion-in-region start stop collection)))

(defun anaconda-mode-complete-extract-names (result)
  "Extract completion names from `anaconda-mode' RESULT."
  (--map (let ((name (aref it 0))
               (type (aref it 1)))
           (put-text-property 0 1 'type type name)
           name)
         result))

(defun anaconda-mode-complete-annotation (candidate)
  "Get annotation for CANDIDATE."
  (--when-let (get-text-property 0 'type candidate)
    (concat " <" it ">")))


;;; View documentation.

(defun anaconda-mode-show-doc ()
  "Show documentation for context at point."
  (interactive)
  (anaconda-mode-call "show_doc" 'anaconda-mode-show-doc-callback))

(defun anaconda-mode-show-doc-callback (result)
  "Process view doc RESULT."
  (if result
      (pop-to-buffer
       (anaconda-mode-documentation-view result))
    (message "No documentation available")))

(defun anaconda-mode-documentation-view (result)
  "Show documentation view for rpc RESULT."
  (let ((buf (get-buffer-create "*Anaconda*")))
    (with-current-buffer buf
      (view-mode -1)
      (erase-buffer)
      (--map
       (progn
         (insert (propertize (aref it 0) 'face 'bold))
         (insert "\n")
         (insert (s-trim-right (aref it 1)))
         (insert "\n\n"))
       result)
      (view-mode 1)
      (goto-char (point-min))
      buf)))


;;; Find definitions.

(defun anaconda-mode-find-definitions ()
  "Find definitions for thing at point."
  (interactive)
  (anaconda-mode-call
   "goto_definitions"
   (lambda (result)
     (anaconda-mode-show-xrefs result nil "No definitions found"))))

(defun anaconda-mode-find-definitions-other-window ()
  "Find definitions for thing at point."
  (interactive)
  (anaconda-mode-call
   "goto_definitions"
   (lambda (result)
     (anaconda-mode-show-xrefs result 'window "No definitions found"))))

(defun anaconda-mode-find-definitions-other-frame ()
  "Find definitions for thing at point."
  (interactive)
  (anaconda-mode-call
   "goto_definitions"
   (lambda (result)
     (anaconda-mode-show-xrefs result 'frame "No definitions found"))))


;;; Find assignments.

(defun anaconda-mode-find-assignments ()
  "Find assignments for thing at point."
  (interactive)
  (anaconda-mode-call
   "goto_assignments"
   (lambda (result)
     (anaconda-mode-show-xrefs result nil "No assignments found"))))

(defun anaconda-mode-find-assignments-other-window ()
  "Find assignments for thing at point."
  (interactive)
  (anaconda-mode-call
   "goto_assignments"
   (lambda (result)
     (anaconda-mode-show-xrefs result 'window "No assignments found"))))

(defun anaconda-mode-find-assignments-other-frame ()
  "Find assignments for thing at point."
  (interactive)
  (anaconda-mode-call
   "goto_assignments"
   (lambda (result)
     (anaconda-mode-show-xrefs result 'frame "No assignments found"))))


;;; Find references.

(defun anaconda-mode-find-references ()
  "Find references for thing at point."
  (interactive)
  (anaconda-mode-call "usages"
                      (lambda (result)
                        (anaconda-mode-show-xrefs result nil "No references found"))))

(defun anaconda-mode-find-references-other-window ()
  "Find references for thing at point."
  (interactive)
  (anaconda-mode-call "usages"
                      (lambda (result)
                        (anaconda-mode-show-xrefs result 'window "No references found"))))

(defun anaconda-mode-find-references-other-frame ()
  "Find references for thing at point."
  (interactive)
  (anaconda-mode-call "usages"
                      (lambda (result)
                        (anaconda-mode-show-xrefs result 'frame "No references found"))))


;;; Xref.

(defun anaconda-mode-show-xrefs (result display-action error-message)
  "Show xref from RESULT using DISPLAY-ACTION.
Show ERROR-MESSAGE if result is empty."
  (if result
      (xref--show-xrefs (anaconda-mode-make-xrefs result) display-action)
    (message error-message)))

(defun anaconda-mode-make-xrefs (result)
  "Return a list of x-reference candidates created from RESULT."
  (--map
   (xref-make
    (aref it 3)
    (xref-make-file-location (aref it 0) (aref it 1) (aref it 2)))
   result))


;;; Eldoc.

(defun anaconda-mode-eldoc-function ()
  "Show eldoc for context at point."
  (anaconda-mode-call "eldoc" 'anaconda-mode-eldoc-callback)
  ;; Don't show response buffer name as ElDoc message.
  nil)

(defun anaconda-mode-eldoc-callback (result)
  "Display eldoc from server RESULT."
  (eldoc-message (anaconda-mode-eldoc-format result)))

(defun anaconda-mode-eldoc-format (result)
  "Format eldoc string from RESULT."
  (when result
    (let ((doc (anaconda-mode-eldoc-format-definition
                (aref result 0)
                (or (aref result 1) 0)
                (aref result 2))))
      (if anaconda-mode-eldoc-as-single-line
          (substring doc 0 (min (frame-width) (length doc)))
        doc))))

(defun anaconda-mode-eldoc-format-definition (name index params)
  "Format function definition from NAME, INDEX and PARAMS."
  (aset params index (propertize (aref params index) 'face 'eldoc-highlight-function-argument))
  (concat (propertize name 'face 'font-lock-function-name-face) "(" (mapconcat 'identity params ", ") ")"))


;;; Anaconda minor mode.

(defvar anaconda-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-M-i") 'anaconda-mode-complete)
    (define-key map (kbd "M-.") 'anaconda-mode-find-definitions)
    (define-key map (kbd "C-x 4 .") 'anaconda-mode-find-definitions-other-window)
    (define-key map (kbd "C-x 5 .") 'anaconda-mode-find-definitions-other-frame)
    (define-key map (kbd "M-*") 'anaconda-mode-find-assignments)
    (define-key map (kbd "C-x 4 *") 'anaconda-mode-find-assignments-other-window)
    (define-key map (kbd "C-x 5 *") 'anaconda-mode-find-assignments-other-frame)
    (define-key map (kbd "M-r") 'anaconda-mode-find-references)
    (define-key map (kbd "C-x 4 r") 'anaconda-mode-find-references-other-window)
    (define-key map (kbd "C-x 5 r") 'anaconda-mode-find-references-other-frame)
    (define-key map (kbd "M-,") 'xref-pop-marker-stack)
    (define-key map (kbd "M-?") 'anaconda-mode-show-doc)
    map)
  "Keymap for `anaconda-mode'.")

;;;###autoload
(define-minor-mode anaconda-mode
  "Code navigation, documentation lookup and completion for Python.

\\{anaconda-mode-map}"
  :lighter anaconda-mode-lighter
  :keymap anaconda-mode-map)

;;;###autoload
(define-minor-mode anaconda-eldoc-mode
  "Toggle echo area display of Python objects at point."
  :lighter ""
  (if anaconda-eldoc-mode
      (turn-on-anaconda-eldoc-mode)
    (turn-off-anaconda-eldoc-mode)))

(defun turn-on-anaconda-eldoc-mode ()
  "Turn on `anaconda-eldoc-mode'."
  (make-local-variable 'eldoc-documentation-function)
  (setq-local eldoc-documentation-function 'anaconda-mode-eldoc-function)
  (eldoc-mode +1))

(defun turn-off-anaconda-eldoc-mode ()
  "Turn off `anaconda-eldoc-mode'."
  (kill-local-variable 'eldoc-documentation-function)
  (eldoc-mode -1))

(provide 'anaconda-mode)

;;; anaconda-mode.el ends here
