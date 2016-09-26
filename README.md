# LDAPGraph

LDAPGraph is a data collection daemon for the OpenLDAP monitor backend. 
It can be used to display graphs/trends of various information that the OpenLDAP server can keep score of. 
Thus it can be used to see how many queries the ldap server processes and general used to determine when you have a heavy load on your LDAP Server. 
It has been developed for use at [Aalborg University, Department of Computer Science](http://cs.aau.dk), and was being used on 8 production LDAP Servers in this and other departmens at the university.

## Technical

The tool is based on an perl script pasted on the OpenLDAP mailinglists a long while ago (10 years or something), and basically it is a perl daemon which every five minutes queries a series of OpenLDAP servers for their "monitor" values, and stores them in a database. 
The "database" is in Tobias Oetikers RRD format which is developed for the purpose of recording and displaying time series data (such as this). 
This data can then be displayed using some sort of CGI script, an example cgi is included in the release relying on the same configuration format as the daemon it self.

You can find an example HTML of the result using the given Perl CGI at http://ofn.dk/ldapgraph/examples/server/foo.html

### Requirements

Various perl modules are needed:
* Posix
* LDAP
* Config
* RRDs.pm

Addiotnally I seem to recall that OpenLdap had to be compiled with statistics enabled.

As the system is based on Perl, it should theoretically run on anything that has a perl interpreter, but im guessing that is unlikely. 
I have tested this on Red Hat Enterprise Linux WS 4.0 (x86) and Suse Linux Enterprise Server+Desktop 10.0 (x86_64), and a Debian 4.0 (x86). 
So basically if you run Linux/Unix your are likely able to make it work.

# Warning!

This code is not exactly new, but it could work as a starting point for someone other than me, so feel free to abuse it any way you want - but don't expect it to run right out of the box without some tweaking.