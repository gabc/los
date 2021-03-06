;;;								-*- Lisp -*-
;;; strings.asd -- System definition for strings
;;;

(defsystem strings
    :name               "strings"
    :description        "Try to extract human readable strings from data."
    :version            "0.1.0"
    :author             "Nibby Nebbulous <nibbula -(. @ .)- gmail.com>"
    :license            "GPLv3"
    :source-control	:git
    :long-description
    "Try to extract human readable strings from data."
    :depends-on (:dlib :stretchy :lish)
    :components
    ((:file "strings")))
