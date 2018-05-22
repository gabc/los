;;
;; ls.lisp - list your shit
;;

;; Actually I really hate this command. I'm so sick of hierarchical file
;; systems. I want to mutate this into a tag browser to surf my metadata.
;;
;; I mostly just wanted to implement this square wheel because:
;;   - Unix ls loses at making columns out of multibyte characters.
;;   - I wish it had slightly better column smushing behavior.
;;   - Object collecting.
;;   - It's the command I type the most. So I want it to be in Lisp.
;;   - I dream of someday finally "rm /usr/bin /bin".

(defpackage :ls
  (:documentation
   "This is a shitty fake implementation of the command I type the most.")
  (:use :cl :dlib :opsys :dlib-misc :grout :style :terminal :table :table-print
	:terminal-table :magic :fatchar)
  (:export
   #:!ls
   #:ls
   #:list-files
   ))
(in-package :ls)

;; Dynamic state
(defstruct ls-state
  today
  about-a-year
  table-renderer
  outer-terminal
  mixed-bag)
(defparameter *ls-state* nil)

(defclass file-item ()
  ((name
    :initarg :name #| :accessor file-item-name |#
    :documentation "Name of the file, likely without a directory.")
   (directory
    :initarg :directory :accessor file-item-directory
    :documentation "The directory the file is in."))
  (:documentation "The minimal file item. Just the name."))

(defclass file-item-with-info (file-item)
  ((info
   :initarg :info :accessor file-item-info
   :documentation "Whatever."))
  (:documentation "A generic file item with more info."))

(defclass file-item-dir (file-item-with-info)
  ()
  (:documentation
   "The file item with directory info. INFO slot is DIR-ENTRY structure retuned
by nos:read-directory."))

(defclass file-item-full (file-item-with-info)
  ()
  (:documentation "A full OS specific file info."))

#+unix
(defclass file-item-unix (file-item-full)
  ()
  (:documentation "uos:stat."))

#+windows
(defclass file-item-windows (file-item-full)
  ()
  (:documentation "wos:whatever."))

(defgeneric file-item-name (item)
  (:documentation "Return the file-item name.")
  (:method ((item string))
    item)
  (:method ((item file-item))
    (slot-value item 'name)))

(defgeneric file-item-creation-date (item)
  (:documentation "Return creation time as a dtime.")
  (:method ((item file-item-unix))
    ;; This is wrong-ish. See unix:convert-file-info
    (make-dtime :seconds (uos:unix-to-universal-time
			  (uos:timespec-seconds
			   (uos:file-status-modify-time
			    (file-item-info item))))))
  (:method ((item file-item-full))
    (make-dtime :seconds (nos:file-info-creation-time
			  (file-item-info item)))))

(defgeneric file-item-access-date (item)
  (:documentation "Return access time as a dtime.")
  (:method ((item file-item-unix))
    (make-dtime :seconds (uos:unix-to-universal-time
			  (uos:timespec-seconds
			   (uos:file-status-access-time
			    (file-item-info item))))))
  (:method ((item file-item-full))
    (make-dtime :seconds (nos:file-info-access-time
			  (file-item-info item)))))

(defgeneric file-item-modification-date (item)
  (:documentation "Return modification time as a dtime.")
  (:method ((item file-item-unix))
    ;; This is wrong-ish. See unix:convert-file-info
    (make-dtime :seconds (uos:unix-to-universal-time
			  (uos:timespec-seconds
			   (uos:file-status-change-time
			    (file-item-info item))))))
  (:method ((item file-item-full))
    (make-dtime :seconds (nos:file-info-modification-time
			  (file-item-info item)))))

(defgeneric file-item-size (item)
  (:documentation "Return the size in bytes.")
  (:method ((item file-item-unix))
    (uos:file-status-size (file-item-info item)))
  (:method ((item file-item-full))
    (nos:file-info-size (file-item-info item))))

(defgeneric file-item-type (item)
  (:documentation "Return the type.")
  (:method ((item file-item-unix))
    (uos:symbolic-mode (uos:file-status-mode (file-item-info item))))
  (:method ((item file-item-full))
    (nos:file-info-type (file-item-info item))))

;; @@@ figure out the best way to get rid of this
(defgeneric file-item-as-dir-entry (item)
  (:documentation "Return the size in bytes.")
  (:method ((item file-item-dir))
    (file-item-info item))
  (:method ((item file-item-unix))
    (make-dir-entry
     :name (file-item-name item)
     :type (uos:file-type-symbol
	    (uos:file-status-mode (file-item-info item)))))
  (:method ((item file-item-full))
    (make-dir-entry
     :name (file-item-name item)
     :type (nos:file-info-type (file-item-info item))))
  (:method ((item file-item))
    (file-item-as-dir-entry (make-full-item item)))
  (:method ((item string))
    (file-item-as-dir-entry (make-full-item item))))

(defun full-path (dir file)
  (if dir
      (path-append dir (file-item-name file))
      (file-item-name file)))

(defun item-full-path (item)
  (if (file-item-directory item)
      (path-append (file-item-directory item) (file-item-name item))
      (file-item-name item)))

(defun make-full-item (item &optional dir)
  (etypecase item
    (string
     (make-instance #+unix 'file-item-unix
		    #-unix 'file-item-full
		    :name item
		    :directory dir
		    :info
		    #-unix (nos:get-file-info (full-path dir item))
		    #+unix (uos:stat (full-path dir item))))
    ((or file-item-dir file-item)
     (let ((this-dir (or dir (file-item-directory item))))
       (make-instance #+unix 'file-item-unix
		      #-unix 'file-item-full
		      :name (file-item-name item)
		      :directory this-dir
		      :info
		      #-unix (nos:get-file-info
			      (full-path this-dir (file-item-name item)))
		      #+unix (uos:stat
			      (full-path this-dir (file-item-name item))))))
    (file-item-full
     item)))

(defun make-at-least-dir (item)
  (etypecase item
    (string (make-full-item item))
    (file-item-dir item)))

(defun ensure-full-info (file-list dir)
  (mapcar (_ (make-full-item _ dir)) file-list))

(defun format-the-date (time format)
  "Given a universal-time, return a date string according to FORMAT."
  (case format
    (:nibby
     (date-string :time time))
    (:normal
     (let ((d (make-dtime :seconds time)))
       (if (dtime< d (dtime- (ls-state-today *ls-state*)
			     (ls-state-about-a-year *ls-state*)))
	   (format-date "~a ~2d ~4,'0d" (:month-abbrev :day :year)
			:time time)
	   (format-date "~a ~2d ~2,'0d:~2,'0d" (:month-abbrev :day :hour :min)
			:time time))))))

(defun format-the-size (size)
  (remove #\space (print-size size :traditional t :stream nil :unit "")))

(defun get-styled-file-name (file-item)
  "File is eigher a string or a dir-entry. Return a possibly fat-string."
  (typecase file-item
    (dir-entry
     (styled-file-name file-item))
    (string
     (styled-file-name (file-item-as-dir-entry file-item)))
    (file-item
     (if (ls-state-mixed-bag *ls-state*)
	 ;; Make a full path name.
	 (let ((duh (file-item-as-dir-entry file-item)))
	   (styled-file-name
	    (path-append (file-item-directory file-item)
			 (file-item-name file-item))
	    (dir-entry-type duh)))
	 (styled-file-name (file-item-as-dir-entry file-item))))
    (t file-item)))

(defun plain-file-name (file)
  (typecase file
    (dir-entry (dir-entry-name file))
    (t file)))

(defun mime-type-string (file table)
  (or (gethash file table)
      (setf (gethash file table)
	    (let ((type (magic:guess-file-type (file-item-name file))))
	      (or (and type
		       (s+ (magic:content-type-category type)
			   "/"
			   (magic:content-type-name type)))
		  "")))))

(defun sort-files-by (file-list key &optional reverse dir)
  (case key
    (:name
     (sort-muffled file-list (if reverse #'string> #'string<)
		   :key #'file-item-name))
    (:size
     (sort-muffled (ensure-full-info file-list dir)
		   (if reverse #'> #'<)
		   :key #'file-item-size))
    (:type
     (sort-muffled (ensure-full-info file-list dir)
		   (if reverse #'string> #'string<)
		   :key (_ (string (file-item-type _)))))
    (:access-time
     (sort-muffled (ensure-full-info file-list dir)
		   (if reverse #'dtime> #'dtime<)
		   :key (_ (file-item-access-date _))))
    (:creation-time
     (sort-muffled (ensure-full-info file-list dir)
		   (if reverse #'dtime> #'dtime<)
		   :key (_ (file-item-creation-date _))))
    (:modification-time
     (sort-muffled (ensure-full-info file-list dir)
		   (if reverse #'dtime> #'dtime<)
		   :key (_ (file-item-modification-date _))))
    (:extension
     (let ((str-func (if reverse #'string> #'string<)))
       (sort-muffled file-list
		     (lambda (a b)
		       (cond
			 ((and (not (car a)) (not (car b)))
			  (funcall str-func (cdr a) (cdr b)))
			 (t
			  (funcall str-func (car a) (car b)))))
		   :key (_ (cons
			    (path-extension (file-item-name _))
			    (file-item-name _))))))
    (:mime-type
     ;; This is quite slow.
     (let ((str-func (if reverse #'string> #'string<))
	   (table (make-hash-table :test #'equal)))
       (sort-muffled file-list str-func
		     :key (_ (mime-type-string _ table)))))
    (:none
     file-list)
    (otherwise
     file-list)))

(defun make-default-state ()
  (make-ls-state
   :outer-terminal *terminal*
   :today (get-dtime)
   :about-a-year (make-dtime :seconds (weeks-to-time 50))
   :table-renderer (make-instance
		    'terminal-table:terminal-table-renderer)))

#+unix
(defun unix-stat (path)
  (handler-case
      (uos:stat path)
    (uos:posix-error (c)
      (when (= (opsys-error-code c) uos:+ENOENT+)
	(uos:lstat path)))))

(defun list-long (file-list date-format)
  "Return a table filled with the long listing for files in FILE-LIST."
  #+unix
  (make-table-from
   (loop
      :for file :in file-list
      ;;:for s = (unix-stat (item-full-path file))
      :for s = (uos:lstat (item-full-path file))
      :collect
      (list
       (uos:symbolic-mode (uos:file-status-mode s))
       (uos:file-status-links s)
       (or (user-name (uos:file-status-uid s)) (uos:file-status-uid s))
       (or (group-name (uos:file-status-gid s)) (uos:file-status-gid s))
       (format-the-size (uos:file-status-size s))
       (format-the-date
	(uos:unix-to-universal-time
	 (uos:timespec-seconds
	  (uos:file-status-modify-time s)))
	(keywordify date-format))
       (if (uos:is-symbolic-link (uos:file-status-mode s))
	   (fs+ (get-styled-file-name file) " -> "
		(uos:readlink (item-full-path file)))
	   (get-styled-file-name file))))
   :column-names
   '("Mode" "Links" "User" "Group" ("Size" :right) "Date" "Name"))
  #-unix ;; @@@ not even tested yet
  (make-table-from
   (loop
      :for file :in file-list
      :for s = (nos:get-file-info (dir-entry-name file))
      :collect (list
		(file-info-type s)
		(file-info-flags s)
		(format-the-size (file-info-size s))
		(format-the-date
		 (file-info-modification-time s))
		file))
   '("Type" "Flags" ("Size" :right) "Date" "Name")))

(defun format-short (file dir show-size)
  (if show-size
      (format nil "~6@a ~a"
	      (format-the-size (file-item-size (make-full-item file dir)))
	      (get-styled-file-name file))
      (get-styled-file-name file)))

(defun format-short-item (item show-size)
  (if show-size
      (format nil "~6@a ~a"
	      (format-the-size (file-item-size (make-full-item item)))
	      (get-styled-file-name item))
      (get-styled-file-name item)))

(defun gather-file-info (args)
  ;;(format t "gather files -> ~s~%" (getf args :files))
  (let* (main-list
	 (sort-by (getf args :sort-by))
	 (results
	  (loop :for file :in (getf args :files)
	     :if (and (probe-directory file)
		      (not (getf args :directory)))
	     :collect
	     (mapcar (_ (make-instance
			 'file-item-dir
			 :name (dir-entry-name _)
			 :directory file
			 :info _))
		     (read-directory
		      :full t :dir file
		      :omit-hidden (not (getf args :hidden))))
	     :else
	     :do
	     (push (make-instance 'file-item
				  :name (path-file-name file)
				  ;; @@@ wasteful? make pre-done dir?
				  :directory (path-directory-name file))
		   main-list)
	     (setf (ls-state-mixed-bag *ls-state*) t))))
    ;; group all the individual files into a list
    (setf results
	  (if main-list
	      (append (list (nreverse main-list)) results)
	      results)
	  sort-by (if sort-by (keywordify sort-by) :none))
    (when (not (eq sort-by :none))
      (setf results
	    (loop :for list :in results
	       :collect
	       (sort-files-by list sort-by (getf args :reverse)))))
    results))

(defun present-files (files args)
  ;;(format t "present files -> ~s~%" files)
  (with-grout ()
    (flet ((print-it (x)
	     (if (getf args :long)
		 (grout-print-table (list-long x (getf args :date-format))
				    :long-titles nil :trailing-spaces nil)
		 (print-columns
		  (mapcar (_ (format-short-item _ (getf args :show-size))) x)
		  :smush t :format-char "/fatchar:print-string/"
		  :stream (or *terminal* *standard-output*)
		  :columns (terminal-window-columns
			    (or (ls-state-outer-terminal *ls-state*)
				*terminal*))))))
      (print-it (car files))
      (loop :for list :in (cdr files) ::do
	 (grout-princ #\newline)
	 (print-it list)))))

(defun list-files (&rest args &key files long hidden directory sort-by reverse
				date-format collect show-size)
  (declare (ignorable files long hidden directory sort-by reverse date-format
		      collect show-size))
  ;; It seems like we have to do our own defaulting.
  (when (not files)
    (setf (getf args :files) (list (current-directory))))
  (when (not sort-by)
    (setf (getf args :sort-by) :name))
  (when (not date-format)
    (setf (getf args :date-format) :normal))

  (let* ((*ls-state* (make-default-state))
	 (file-info (gather-file-info args)))
    (present-files file-info args)
    (if collect
	file-info
	(values))))

(defparameter *sort-fields*
  `("none" "name" "size" "access-time" "creation-time" "modification-time"
    "extension" "type" "mime-type"))

#+lish
(lish:defcommand ls
  ((files pathname :repeating t :help "The file(s) to list.")
   (long boolean :short-arg #\l :help "True to list in long format.")
   (hidden boolean :short-arg #\a :help "True to list hidden files.")
   (directory boolean :short-arg #\d
    :help "True to list the directory itself, not its contents.")
   (sort-by choice :long-arg "sort" :help "Field to sort by."
    :default "name"
    :choices ("none" "name" "size" "access-time" "creation-time"
	      "modification-time" "extension" "type" "mime-type"))
   (date-format lenient-choice :short-arg #\f :help "Date format to use."
    :default "normal"
    :choices ("normal" "nibby"))
   (reverse boolean :short-arg #\r :help "Reverse sort order.")
   (show-size boolean :short-arg #\s :help "True to show the file size.")
   (collect boolean :short-arg #\c :help "Collect results as a sequence.")
   ;; Short cut sort args:
   (by-extension boolean :short-arg #\X :help "Sort by file name extension.")
   (by-size boolean :short-arg #\S :help "Sort by size, largest first.")
   (help boolean :long-arg "help" :help "Show the help."))
  :keys-as args
  :accepts (sequence list)
  "List files."
  ;; Translate some args
  (when by-extension
    (remf args :sort-by)
    (setf args (append args '(:sort-by :extension)))
    (remf args :by-extension))
  (when by-size
    (remf args :sort-by)
    (setf args (append args '(:sort-by :size)))
    (remf args :reverse)
    (setf args (append args '(:reverse t)))
    (remf args :by-size))
  (when help
    (lish::print-command-help (lish:get-command "ls"))
    (return-from !ls (values)))
  (flet ((thunk ()
	   (if (and lish:*input* (listp lish:*input*))
	       (apply #'list-files :files lish:*input* args)
	       (apply #'list-files args))))
    (if collect
	(setf lish:*output* (thunk))
	(thunk))))

;; End