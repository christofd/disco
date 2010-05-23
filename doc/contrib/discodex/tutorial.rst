Tutorial
========

This tutorial will walk you through the steps necessary to get Discodex
up and running on your local machine.
It will also walk you through the basic concepts of building and querying
indices with Discodex.
To install Discodex on a server or using a remote Disco master, you should
only need to change a few :mod:`discodex.settings`.

0. Install Discodex
-------------------

To run Discodex, the Python package and command line utility must be installed.
See :mod:`discodex <discodexcli>` for information on installing the command line utility.
You can install the Python package either using a symlink, or by running::

        make install-discodex

1. Start Disco
--------------

If you haven't already started a Disco master, you will need to do so now.
Discodex requires that a Disco master be running at ``DISCODEX_DISCO_MASTER``,
so that it can submit jobs to it.

Usually, you can start Disco simply by running::

        disco start

For more information on starting Disco, see :ref:`setup`.

2. Start Discodex
-----------------

Discodex runs its own HTTP server which translates HTTP requests into
Disco jobs.
In order to use Discodex, you will need to start the server::

         discodex start

3. Build an Index
-----------------

Discodex makes it easy to build indices from data, assuming you know how you
want to create keys and values from your data.
The default :mod:`parser <discodex.mapreduce.parsers>` for Discodex,
is ``rawparse``.
It simply takes the string attached to ``raw://`` URLs, and decodes them in
a special way to produce keys and values::

        echo raw://hello:world | discodex index

If you check the disco status web page, you can still see the job Discodex
executed to build the index.
If you see the 'green light' next to the job, you've successfully built
your first index!
The job will remain there until you read it for the first time.
Officially, it won't become an index until you read it using
``discodex get`` or some other command (such as ``discodex clone``).
You can confirm that you don't see it yet when you do::

        discodex list

Using the name of the job returned from the ``discodex index`` command,
let's go ahead and make it official::

        discodex get <INDEX>

You should see the `tag` object stored on DDFS printed out.
You should also see the index name now when you do::

        discodex list

Let's copy the index to a more human-readable name::

        discodex clone <INDEX> toyindex

Once more, let's see whats available::

        discodex list

Notice the prefix.
This is the prefix stored in the settings `DISCODEX_INDEX_PREFIX`.
Generally speaking, you can ignore this prefix and just use the name you gave it.
The reason it exists is to provide `discodex` with its own namespace in :ref:`ddfs`, where the indices are stored.

Let's try seeing the keys stored in the index::

        discodex keys toyindex

And the values::

        discodex values toyindex

Let's also try querying it::

        discodex query toyindex hello

If you have :mod:`ddfs <ddfscli>` installed, you can try::

        ddfs ls
        ddfs ls discodex

Notice how the indices are just tags stored on DDFS.

Now that we've created our first index and queried it, let's clean up our mess::

        discodex list | xargs -n 1 discodex delete

You could have also done::

        ddfs ls discodex: | xargs ddfs rm

.. warning:: Be careful, these commands will delete all your indices!

3. Querying the index
---------------------

Let's build a slightly more complicated index and try querying it::

        echo raw://hello:world,hello:there,hi:world,hi:mom | discodex index
        discodex clone <index> rawindex

Go ahead and try the following queries::

        discodex query rawindex hello
        discodex query rawindex hi
        discodex query rawindex hello hi
        discodex query rawindex hello,hi

Discodex queries the underlying :mod:`discodb` objects using
:term:`conjunctive normal form`.
In queries from the command line, you can use spaces to separate clauses,
and commas to separate literals.

4. Index the docs
-----------------

Let's try indexing some real files now.
We can use the Disco documentation::

        find $DISCO_HOME/doc -name \*.rst | discodex index --parser wordparse

.. note:: Any text files will work, just make sure to pass absolute paths.

Let's name the index::

        discodex clone <INDEX> words

If you indexed the docs as above,
you can now see which files contain the word ``discodex``::

        discodex query words discodex

We can also see which files contain the words ``discodex`` *and* ``build``::

        discodex query words discodex build

Congratulations, you've built a basic search engine!

5. Build a Metaindex
--------------------

A :term:`metaindex` is an index built on top of the keys of another index.
The easiest way to understand what it does is probably just to build one.
As an example, let's build a metaindex of our ``words`` index to
make our documentation search engine slightly more robust::

        discodex metaindex --metakeyer prefixkeyer words
        discodex clone <METAINDEX> metawords

Using the ``prefixkeyer``, we mapped all possible prefixes of all of the keys
in our index to the keys themselves, and stored them in the metaindex,
along with the original index.
Now if we query our metaindex,
we can see not only the files which contain the exact words we are querying,
but any files which contain words *starting* with our query words::

        discodex query metawords discodex build

Hopefully at this point, you can imagine writing
:mod:`discodex.mapreduce.metakeyers`, that allow you to query your data in
all kinds of interesting ways.

6. Advanced Querying Using Filters
----------------------------------

.. todo:: query filters not covered yet