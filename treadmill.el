;;; treadmill-mode.el --- Development environment for Gerbil Scheme -*- lexical-binding: t -*-

;; Copyright © 2018 Thunk NYC Corp.
;;
;; Author: Edwin Watkeys <edw@poseur.com>
;;
;; URL: https://github.com/thunknyc/emacs-treadmill
;; Keywords: languages gerbil scheme lisp
;; Version: 0.1-snapshot
;; Package-Requires: ((emacs "25.1") (company "0.9.0") (cl-lib "0.3"))

;; Permission is hereby granted, free of charge, to any person
;; obtaining a copy of this software and associated documentation
;; files (the "Software"), to deal in the Software without
;; restriction, including without limitation the rights to use, copy,
;; modify, merge, publish, distribute, sublicense, and/or sell copies
;; of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be
;; included in all copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;; NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
;; BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
;; ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
;; CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:

;; Provides an interaction buffer and a minor-mode for Gerbil Scheme
;; code.

;;; Usage:

;; Start a Gerbil network repl and connect:
;; M-x treadmill-spawn

;; Connect to an existing Gerbil network repl:
;; M-x treadmill-connect

;;; Code:

(require 'gerbil)
(require 'subr-x)

(defvar treadmill-interpreter-name nil)
(defconst treadmill-default-host "127.0.0.1")

(defvar treadmill-current-interaction-buffer nil)

(defvar-local treadmill-spawn-port nil)
(defvar-local treadmill-spawn-process nil)
(defvar-local treadmill-repl-awaiting-value nil)

(defvar-local treadmill-interaction-buffer nil)
(defvar-local treadmill-repl-process nil)

(defvar-local treadmill-ia-mark nil)

(defun treadmill-find-pkg (dir)
  (let ((pkg-file (format "%s/gerbil.pkg" dir)))
    (when (file-readable-p pkg-file)
        (let ((b (generate-new-buffer "*treadmill-find-pkg*")))
          (with-current-buffer b
            (insert-file-contents pkg-file)
            (let* ((txt (buffer-substring (point-min) (point-max)))
                   (alist (read (format "(%s)" txt))))
              (kill-buffer)
              (symbol-name (car (alist-get 'package: alist)))))))))

(defun treadmill-build-module-name (els fdir)
  (if (string-empty-p fdir) nil
    (if-let ((pkg (treadmill-find-pkg fdir)))
        (string-join (cons pkg els) "/")
        (let ((el (file-name-nondirectory fdir)))
          (treadmill-build-module-name
           (cons el els)
           (substring (file-name-directory fdir) 0 -1))))))

(defun treadmill-gerbil-current-module ()
  (interactive)
  (cond ((bound-and-true-p treadmill-current-module)
         treadmill-current-module)
        ((not (buffer-file-name))
         (warn "No module name for Gerbil unsaved buffer."))
        (t (let* ((fname (buffer-file-name))
                  (module-leaf (file-name-sans-extension
                                (file-name-nondirectory fname)))
                  (fdir (substring (file-name-directory fname) 0 -1)))
             (if-let ((module (treadmill-build-module-name
                               (list module-leaf) fdir)))
                 (progn (setq treadmill-current-module module)
                        module)
               (warn "No package file name for Gerbil source."))))))

(defun treadmill-gxi-location ()
  (let ((gerbil-home (getenv "GERBIL_HOME")))
    (cond ((and (bound-and-true-p treadmill-interpreter-name)
                (not (string-empty-p treadmill-interpreter-name)))
           treadmill-interpreter-path)
          (gerbil-home
           (format "%s/bin/gxi" gerbil-home))
          (t nil))))

;;###autoload
(defun treadmill-spawn ()
  (interactive)
  (treadmill-start-server))

(defun treadmill-command ()
  (list (treadmill-gxi-location)
        "-e" "(import :thunknyc/treadmill) (start-treadmill!)"))

(defvar-local treadmill-repl-error-level nil)

(defun treadmill-repl-value ()
  (goto-char (point-max))
  (when (search-backward-regexp "\r\n\\([0-9]*\\)> " nil t)
    (let ((prompt (match-string 0))
          (error-level (match-string 1)))
      (if (string-empty-p error-level)
          (setq treadmill-repl-error-level nil)
        (setq treadmill-repl-error-level (string-to-number error-level)))
      (buffer-substring 1 (- (point-max) (length prompt))))))

(defun treadmill-lowlevel-completion-filter (proc)
  (let ((proc proc))
    (lambda (p s)
      ;; Boilerplate
      (when (buffer-live-p (process-buffer p))
        (with-current-buffer (process-buffer p)
          (let ((moving (= (point) (process-mark p))))
            (save-excursion
              ;; Insert the text, advancing the process marker.
              (goto-char (process-mark p))
              (insert s)
              (set-marker (process-mark p) (point)))
            (if moving (goto-char (process-mark p))))))
      ;; Not boilerplate
      (with-current-buffer (process-buffer p)
        (when treadmill-repl-awaiting-value
          (save-excursion
            (goto-char (point-max))
            (when (search-backward-regexp "\r\n[0-9]*> " nil t)
              (setq treadmill-repl-awaiting-value nil)
              (let ((result (string-trim (treadmill-repl-value))))
                (when (not (zerop (length result)))
                  (funcall proc result))))))))))

(defun treadmill-repl-completion-filter (proc)
  (lambda (p s)
    ;; Boilerplate
    (when (buffer-live-p (process-buffer p))
      (with-current-buffer (process-buffer p)
        (let ((moving (= (point) (process-mark p))))
          (save-excursion
            ;; Insert the text, advancing the process marker.
            (goto-char (process-mark p))
            (insert s)
            (set-marker (process-mark p) (point)))
          (if moving (goto-char (process-mark p))))))
    ;; Not boilerplate
    (with-current-buffer (process-buffer p)
      (when treadmill-repl-awaiting-value
        (save-excursion
          (goto-char (point-max))
          (when (search-backward-regexp "\r\n[0-9]*> " nil t)
            (setq treadmill-repl-awaiting-value nil)
            (let ((result (string-trim (treadmill-repl-value))))
              (when (not (zerop (length result)))
                (funcall proc (read result))))))))))

(defun treadmill-repl-filter (p s)
  ;; Boilerplate
  (when (buffer-live-p (process-buffer p))
    (with-current-buffer (process-buffer p)
      (let ((moving (= (point) (process-mark p))))
        (save-excursion
          ;; Insert the text, advancing the process marker.
          (goto-char (process-mark p))
          (insert s)
          (set-marker (process-mark p) (point)))
        (if moving (goto-char (process-mark p))))))
  ;; Not boilerplate
  (with-current-buffer (process-buffer p)
    (when treadmill-repl-awaiting-value
      (save-excursion
        (goto-char 0)
        (when (search-forward-regexp
               "^\\(\\(.*\r\n\\)+\\)[0-9]*> $"
               nil t)
          (setq treadmill-repl-awaiting-value nil)
          (let ((result (string-trim (match-string 1))))
            (if (zerop (length result))
                (message "=> No value")
              (message "=> %S" (read result)))))))))

(defun treadmill-spawn-filter (p s)
  ;; Boilerplate
  (when (buffer-live-p (process-buffer p))
    (with-current-buffer (process-buffer p)
      (let ((moving (= (point) (process-mark p))))
        (save-excursion
          ;; Insert the text, advancing the process marker.
          (goto-char (process-mark p))
          (insert s)
          (set-marker (process-mark p) (point)))
        (if moving (goto-char (process-mark p))))))
  ;; Not boilerplate
  (with-current-buffer (process-buffer p)
    (when (null treadmill-spawn-port)
      (save-excursion
        (goto-char 0)
        (when (search-forward-regexp
               "Running net repl on port \\([0-9]+\\)."
               nil t)
          (let ((port (string-to-number (match-string 1))))
            (setq treadmill-spawn-port port)
            (message "Net repl starting on port %d." port)
            (treadmill-connect "127.0.0.1" port)))))))

(defun treadmill-secure-transcript ()
  (let ((saved-inhibit-read-only inhibit-read-only))
    (setq inhibit-read-only t)
    (add-text-properties (point-min) (point-max)
                         '(front-sticky t rear-nonsticky t read-only t))
    (setq inhibit-read-only saved-inhibit-read-only)))

(defmacro treadmill-inserting (&rest exprs)
  (let ((result (make-symbol "result")))
    `(progn
       (setq inhibit-read-only t)
       (let ((,result (progn ,@exprs)))
         (setq inhibit-read-only nil)
         ,result))))

(defun treadmill-insert (what)
  (let ((saved-inhibit-read-only inhibit-read-only))
    (setq inhibit-read-only t)
    (insert what)
    (setq inhibit-read-only saved-inhibit-read-only)))

(defmacro treadmill-propertizing (properties &rest exprs)
  (let ((beg (make-symbol "beg"))
        (result (make-symbol "result")))
    `(let ((,beg (point))
           (,result (progn ,@exprs)))
       (add-text-properties ,beg (point) ,properties)
       ,result)))

(defun treadmill-issue-prompt ()
  (interactive)
  (goto-char (point-max))
  (treadmill-inserting
   (treadmill-propertizing '(face font-lock-builtin-face)
    (insert (format "%s> " (or treadmill-current-module "TOP")))))
  (setq treadmill-ia-mark (point-max-marker))
  (treadmill-secure-transcript))

(defvar-local treadmill-current-module nil)

(defun treadmill-normalize-module-string (module)
  (cond ((equal module "TOP") nil)
        ((> (length module) 0) module)
        (nil)))

(defun treadmill-gerbil-enter-module (module)
  (interactive "sEnter module: (\"\" for TOP): ")
  (setq treadmill-current-module (treadmill-normalize-module-string module)))

(defun treadmill-ia-enter-module (module)
  (interactive "sEnter module: (\"\" for TOP): ")
  (setq treadmill-current-module (treadmill-normalize-module-string module))
  (let ((unsent-input (buffer-substring-no-properties
                       treadmill-ia-mark (point-max))))
    (goto-char (point-max))
    (insert "\n")
    (treadmill-issue-prompt)
    (insert unsent-input)))

(defun treadmill-insert-result (result)
  (let ((values (car result))
        (stdout (cadr result))
        (stderr (caddr result)))
    (treadmill-propertizing
     '(face font-lock-keyword-face)
     (insert (if (null values) "" (format "%s" values))))
    (if (string-empty-p stdout) ""
      (progn
        (treadmill-propertizing
         '(face font-lock-comment-face)
         (insert (format "\n```stdout\n")))
        (treadmill-propertizing
         '(face font-lock-string-face)
         (insert (format "%s\n" stdout)))
        (treadmill-propertizing
         '(face font-lock-comment-face)
         (insert (format "```")))))
    '(face font-lock-warning-face)
    (if (string-empty-p stderr) ""
      (progn
        (treadmill-propertizing
         '(face font-lock-comment-face)
         (insert (format "\n```stderr\n")))
        (treadmill-propertizing
         '(face font-lock-warning-face)
         (insert (format "%s\n" stderr)))
        (treadmill-propertizing
         '(face font-lock-comment-face)
         (insert (format "```")))))
    (if values (insert "\n"))))

(defvar-local treadmill-history-buffer nil)
(defvar-local treadmill-input-is-history nil)
(defvar-local treadmill-history-changing-buffer nil)

(defun treadmill-history-reset (b e l)
  (when (not treadmill-history-changing-buffer)
    (setq treadmill-input-is-history nil)
    (with-current-buffer treadmill-history-buffer (goto-char (point-max)))))

(defun treadmill-history-replace-input (s)
  (setq treadmill-history-changing-buffer t)
  (if treadmill-input-is-history
      (delete-region treadmill-ia-mark (point-max))
    (kill-region treadmill-ia-mark (point-max)))
  (insert (string-trim s))
  (setq treadmill-history-changing-buffer nil)
  (setq treadmill-input-is-history t))

(defun treadmill-history-advance ()
  (cond ((equal (point) (point-max))    ; nothing to do
         nil)
        (t
         (goto-char (+ (point) 11))
         (if (search-forward ";;;;;;;;;;\n" nil t)
             (goto-char (match-beginning 0))
           (goto-char (point-max))))))

(defun treadmill-history-next ()
  (with-current-buffer treadmill-history-buffer
    (treadmill-history-advance)
    (cond ((equal (point) (point-max))
           (message "No next history item.")
           "")
          (t (let ((expr-start (+ (point) 11)))
               (goto-char expr-start)
               (if (search-forward-regexp ";;;;;;;;;;\n" nil t)
                   (let* ((expr-end (match-beginning 0))
                          (expr (buffer-substring expr-start expr-end)))
                     (goto-char expr-end)
                     expr)
                 (let* ((expr-end (point-max))
                        (expr (buffer-substring expr-start expr-end)))
                   (goto-char expr-end)
                   expr)))))))

(defun treadmill-history-previous ()
  (with-current-buffer treadmill-history-buffer
    (let ((expr-end (point)))
      (cond ((search-backward-regexp ";;;;;;;;;;\n" nil t)
             (let* ((expr-start (match-end 0))
                    (expr (buffer-substring expr-start expr-end)))
               (goto-char (match-beginning 0))
               expr))
            (t (error "No previous history item."))))))

(defun treadmill-ia-history-next ()
  (interactive)
  (let ((h (treadmill-history-next)))
    (treadmill-history-replace-input h)))

(defun treadmill-ia-history-previous ()
  (interactive)
  (let ((h (treadmill-history-previous)))
    (treadmill-history-replace-input h)))

(defun treadmill-push-history-item (input)
  (let ((cleaned (string-trim input)))
    (when (not (string-empty-p cleaned))
      (with-current-buffer treadmill-history-buffer
        (goto-char (point-max))
        (insert ";;;;;;;;;;\n")
        (insert cleaned)
        (insert "\n")))))

(defun treadmill-ia-eval ()
  (interactive)
  (let ((s (buffer-substring-no-properties treadmill-ia-mark (point-max)))
        (stdin "")
        (b (current-buffer)))
    (goto-char (point-max))
    (treadmill-insert "\n")
    (treadmill-push-history-item s)
    (treadmill-eval/io-async
     s stdin treadmill-current-module
     (lambda (result)
       (with-current-buffer b
         (goto-char (point-max))
         (treadmill-inserting (treadmill-insert-result result))
         (treadmill-issue-prompt))))))

;;###autoload
(defun treadmill-connect (host port)
  (interactive
   "sConnect to network REPL at host: \nsREPL port on %s: \n")
  (let* ((repl-b (generate-new-buffer "*treadmill-repl*"))
         (repl-p (open-network-stream "treadmill-repl"
                                      repl-b host port)))
    ;; If treadmill-spawn-process is defined it means we're in the
    ;; spawn buffer and we should connect the spawn buffer with the
    ;; repl buffer, so we can tear down the spawn process when we kill
    ;; the repl.
    (let ((spawn-process treadmill-spawn-process))
      (message "connect via spawn")
      (when spawn-process
        (setq treadmill-repl-process repl-p)
        (with-current-buffer repl-b
          (setq treadmill-spawn-process spawn-process))))
    (message "Repl process is `%s'." repl-p)
    (message "Connected to repl on port %d." port)
    (let ((b (generate-new-buffer "*treadmill*")))
      (setq treadmill-current-interaction-buffer (buffer-name b))
      (with-current-buffer repl-b
        (setq treadmill-interaction-buffer b)
              (setq treadmill-repl-process repl-p))
      (switch-to-buffer b)
      (setq treadmill-repl-process repl-p)
      (setq treadmill-history-buffer
            (generate-new-buffer "*treadmill-history*"))
      (treadmill-propertizing '(face font-lock-comment-face)
       (insert ";;; Welcome to the Gerbil Treadmill\n"))
      (treadmill-eval1 "(begin (import :thunknyc/apropos) (thread-start! (make-thread (lambda () (current-apropos-db)))))")
      (treadmill-issue-prompt)
      (treadmill-mode))))

(defun treadmill-start-server ()
  (let* ((b (generate-new-buffer "*treadmill-spawn*"))
         (p (make-process :name "treadmill-spawn" :buffer b :coding 'utf-8
                          :type 'pipe :command (treadmill-command)
                          :filter 'treadmill-spawn-filter)))
    (with-current-buffer b
      (setq treadmill-spawn-process p))
    (message "Started `%s' in `%s'" p b)
    p))

(defun treadmill-repl-process* (p)
  (buffer-local-value 'treadmill-repl-process (process-buffer p)))

(defun treadmill-eval1-async (s completion)
  (let ((p treadmill-repl-process))
    (with-current-buffer (process-buffer p)
      (erase-buffer)
      (setq treadmill-repl-awaiting-value t)
      (set-process-filter
       p (treadmill-lowlevel-completion-filter completion))
      (process-send-string p (format "%s\n" s)))))

(defmacro with-treadmill (&rest exprs)
  (let ((temp-b (make-symbol "buffer")))
    `(if (bound-and-true-p treadmill-repl-process)
         (progn ,@exprs)
       (let ((,temp-b
              (and treadmill-current-interaction-buffer
                   (get-buffer treadmill-current-interaction-buffer))))
         (with-current-buffer ,temp-b ,@exprs)))))

(defvar-local treadmill-eval-waiting nil)
(defvar-local treadmill-eval-value nil)

(defun treadmill-eval1 (s)
  (with-treadmill
   (setq treadmill-eval-waiting t)
     (let ((b (current-buffer)))
       (treadmill-eval1-async
        s
        (lambda (val)
          (with-current-buffer b
            (setq treadmill-eval-value val)
            (setq treadmill-eval-waiting nil)))))
     (while treadmill-eval-waiting
       (sleep-for 0 50))
     treadmill-eval-value))

(defun treadmill-module-string (mod)
  (if mod
      (format "'%s" mod)
      "#f"))

;; Needs to be called inside an interaction buffer. Procs ending with
;; `*' star need to be passed a spawn process, which sucks, because
;; spawning is not necessary.
(defun treadmill-eval/io-async (expr-string input-string module completion)
  (let ((p treadmill-repl-process))
    (with-current-buffer (process-buffer p)
      (erase-buffer)
      (setq treadmill-repl-awaiting-value t)
      (set-process-filter p (treadmill-repl-completion-filter completion))
      (let ((s (format "(eval-string/input-string %S %S %s)\n"
                       expr-string input-string
                       (treadmill-module-string module))))
        (process-send-string p s)))))

(defun treadmill-repl-quit ()
  (let* ((repl-p treadmill-repl-process)
         (repl-b (current-buffer))
         (spawn-p (buffer-local-value 'treadmill-spawn-process repl-b))
         (spawn-b (if spawn-p (process-buffer spawn-p) nil)))
    (delete-process repl-p)
    (kill-buffer repl-b)
    (when spawn-p
      (delete-process spawn-p)
      (kill-buffer spawn-b))))

(defun treadmill-ia-quit ()
  (interactive)
  (kill-buffer treadmill-history-buffer)
  (with-current-buffer (process-buffer treadmill-repl-process)
    (treadmill-repl-quit))
  (kill-buffer))

(defun treadmill-gerbil-send-region (start end &optional arg)
  (interactive "r")
  (let ((sexp (buffer-substring-no-properties start end))
        (g-b (current-buffer)))
    (if-let ((ia-b (and treadmill-current-interaction-buffer
                        (get-buffer treadmill-current-interaction-buffer))))
        (let* ((module (treadmill-gerbil-current-module)))
          (with-current-buffer ia-b
            (treadmill-eval/io-async
             sexp "" module
             (lambda (val)
               (if arg
                   (with-current-buffer g-b (insert (format "%s" (car val))))
                 (message "=> %s" (car val)))))))
      (error "Treadmill: No current interaction buffer."))))

(defun treadmill-gerbil-send-definition ()
  (interactive)
  (save-excursion
   (end-of-defun)
   (let ((end (point)))
     (beginning-of-defun)
     (treadmill-send-region (point) end))))

(defun treadmill-gerbil-eval-last (arg)
  (interactive "P")
  (treadmill-gerbil-send-region
   (save-excursion (backward-sexp) (point))
   (point)
   arg))

(defun treadmill-gerbil-eval-toplevel ()
  (interactive)
  (save-excursion
   (end-of-defun)
   (let ((end (point)))
     (beginning-of-defun)
     (treadmill-gerbil-send-region (point) end nil))))

(defvar-local treadmill-switch-last-buffer nil)

(defun treadmill-ia-switch ()
  (interactive)
  (if treadmill-switch-last-buffer
      (switch-to-buffer treadmill-switch-last-buffer)
    (error "No most recent Gerbil buffer.")))

(defun treadmill-gerbil-switch ()
  (interactive)
  (let ((b (current-buffer)))
    (switch-to-buffer (get-buffer treadmill-current-interaction-buffer))
    (setq treadmill-switch-last-buffer b)))

(defun treadmill-symbol-at-point ()
  (save-excursion
    (when (re-search-backward "[^-0\\^-9A-Za-z#_%#@!*|+><./?]\\([-0\\^-9A-Za-z#_%#@!*|+><./?]+\\)$")
      (match-string 1))))

(defun treadmill-complete (prefix)
  (let ((expr (format "(complete \"^%s\")" prefix)))
    (message "Expr to eval: %s" expr)
    (read (treadmill-eval1 expr))))

(defun treadmill-complete-meta (name)
  (let ((meta
         (read (treadmill-eval1 (format "(completion-meta \"%s\")" name)))))
    (if meta (format "Modules: %s" (string-join meta " "))
      (format "No information for %s" name))))

(defun treadmill-move-beginning-of-line (n-lines)
  (interactive "^p")
  (cond ((and (eq n-lines 1) (> (point) treadmill-ia-mark))
         (goto-char treadmill-ia-mark))
        (t (move-beginning-of-line n-lines))))

(defvar treadmill-use-company nil)

(when (boundp 'company-mode)
  (require 'cl-lib)
  (defun treadmill-company-backend (command &optional arg &rest ignored)
    (interactive (list 'interactive))
    (cl-case command
      (interactive (company-begin-backend 'treadmill-company-backend))
      (prefix (and (or (eq major-mode 'treadmill-mode)
                       (bound-and-true-p treadmill-gerbil-mode))
                   (let ((sym (company-grab-symbol)))
                     (and (> (length sym) 1)
                          sym))))
      (candidates (treadmill-complete arg))
      (meta (treadmill-complete-meta arg))))
  (add-to-list 'company-backends 'treadmill-company-backend)
  (add-hook 'treadmill-mode-hook #'company-mode)
  (setq treadmill-use-company t))

(defun company-mode-maybe ()
  (if treadmill-use-company
      (company-mode)))

;;###autoload
(defvar treadmill-mode-hook nil)

(defvar treadmill-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") 'treadmill-ia-eval)
    (define-key map (kbd "C-c C-z") 'treadmill-ia-switch)
    (define-key map (kbd "C-c m") 'treadmill-ia-enter-module)
    (define-key map (kbd "C-c q") 'treadmill-ia-quit)
    (define-key map (kbd "M-p") 'treadmill-ia-history-previous)
    (define-key map (kbd "M-n") 'treadmill-ia-history-next)
    (define-key map (kbd "C-a") 'treadmill-move-beginning-of-line)
    map))

(defvar-local after-change-functions nil)

;;###autoload
(defun treadmill-mode ()
  "Major mode for interacting with Gerbil"
  (interactive)
  (use-local-map treadmill-mode-map)
  (setq mode-name "Treadmill Interaction")
  (setq major-mode 'treadmill-mode)
  (company-mode-maybe)
  (add-hook 'after-change-functions 'treadmill-history-reset)
  (run-hooks 'treadmill-mode-hook))

;;###autoload
(define-minor-mode treadmill-gerbil-mode
  "Mode for talking to Treadmill in Gerbil buffers"
  :lighter " TM"
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-c") 'treadmill-gerbil-send-region)
            (define-key map (kbd "C-c C-e") 'treadmill-gerbil-eval-toplevel)
            (define-key map (kbd "C-x C-e") 'treadmill-gerbil-eval-last)
            (define-key map (kbd "C-c C-z") 'treadmill-gerbil-switch)
            (define-key map (kbd "C-M-x") 'treadmill-gerbil-eval-toplevel)
            (define-key map (kbd "C-c m") 'treadmill-gerbil-enter-module)
            map)
  (company-mode-maybe))

;;###autoload
(add-hook 'gerbil-mode-hook 'treadmill-gerbil-mode)

(provide 'treadmill)

;;; treadmill-mode.el ends here